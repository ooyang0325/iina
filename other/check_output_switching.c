// Exercise the runtime audio-output switches IINA performs, and check the two things that
// have broken in practice:
//
//  * the output device is left in a format it advertises as mixable, so that shared-mode
//    playback afterwards is not fed through a non-mixable stream (which bursts), and
//  * playback keeps running across the switch without needing a seek to recover.
//
// Usage: check_output_switching <libmpv> <file> <device-uid> [device-name]
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <mpv/client.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector selector,
                                       AudioObjectPropertyScope scope)
{
    return (AudioObjectPropertyAddress){selector, scope,
                                        kAudioObjectPropertyElementMain};
}

static bool get_prop(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope, void *value, UInt32 size)
{
    AudioObjectPropertyAddress a = addr(selector, scope);
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, value) == noErr;
}

static char *string_prop(AudioObjectID object, AudioObjectPropertySelector selector)
{
    CFStringRef value = NULL;
    if (!get_prop(object, selector, kAudioObjectPropertyScopeGlobal, &value,
                  sizeof(value)) || !value)
        return NULL;
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
                                                     kCFStringEncodingUTF8) + 1;
    char *out = calloc(size, 1);
    CFStringGetCString(value, out, size, kCFStringEncodingUTF8);
    CFRelease(value);
    return out;
}

static AudioDeviceID find_device(const char *needle)
{
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr)
        return 0;
    AudioDeviceID *devices = malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devices);
    AudioDeviceID found = 0;
    for (int n = 0; n < size / sizeof(*devices) && !found; n++) {
        char *name = string_prop(devices[n], kAudioObjectPropertyName);
        if (name && strstr(name, needle))
            found = devices[n];
        free(name);
    }
    free(devices);
    return found;
}

static AudioStreamID output_stream(AudioDeviceID device)
{
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreams,
                                        kAudioDevicePropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr ||
        size < sizeof(AudioStreamID))
        return 0;
    AudioStreamID stream = 0;
    size = sizeof(stream);
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &stream);
    return stream;
}

static AudioStreamBasicDescription physical_format(AudioStreamID stream)
{
    AudioStreamBasicDescription f = {0};
    get_prop(stream, kAudioStreamPropertyPhysicalFormat,
             kAudioObjectPropertyScopeGlobal, &f, sizeof(f));
    return f;
}

#define NON_MIXABLE 0x40

static void describe(const char *label, const AudioStreamBasicDescription *f)
{
    printf("  %-28s %8.1f Hz %2u-bit flags 0x%-3x %s\n", label, f->mSampleRate,
           f->mBitsPerChannel, f->mFormatFlags,
           (f->mFormatFlags & NON_MIXABLE) ? "NON-MIXABLE" : "mixable");
}

static typeof(mpv_set_property_string) *set_property_fn;
static typeof(mpv_get_property_string) *get_property_fn;
static typeof(mpv_wait_event) *wait_event_fn;
static typeof(mpv_free) *free_fn;

// Every time the output decides the device changed underneath it, it tears itself down and
// builds a new one. One or two of those across a switch is normal. A stream of them is the
// output reacting to its own format change, which never settles, so playback never starts
// and only a seek gets it going again.
static int reload_requests;
// Underruns mean the device ran out of samples and played whatever was in the buffer.
// A steady stream of them is what a burst of noise sounds like.
static int underruns;

static void pump(mpv_handle *mpv, double seconds)
{
    for (double t = 0; t < seconds; t += 0.05) {
        mpv_event *event = wait_event_fn(mpv, 0.05);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            if (strstr(message->text, "Stream format changed"))
                reload_requests++;
            if (strstr(message->text, "underrun"))
                underruns++;
        }
    }
}

static double time_pos(mpv_handle *mpv)
{
    char *value = get_property_fn(mpv, "time-pos");
    double result = value ? atof(value) : -1;
    free_fn(value);
    return result;
}

// Playback is only really running if the position moves while unpaused. Rebuilding the
// output takes a moment, so allow for that: what matters is that playback resumes on its
// own, not that it never pauses. The bug this guards against never resumes at all until
// the user seeks.
static bool playback_advances(mpv_handle *mpv, const char *stage, int *failures)
{
    char *paused = get_property_fn(mpv, "pause");
    bool is_paused = paused && !strcmp(paused, "yes");
    free_fn(paused);

    double before = time_pos(mpv);
    double after = before;
    for (int n = 0; n < 16 && !(after > before); n++) {
        pump(mpv, 0.5);
        after = time_pos(mpv);
    }

    bool ok = !is_paused && after > before;
    printf("  %-28s pause=%s %.2f -> %.2f s\n", stage, is_paused ? "yes" : "no",
           before, after);
    if (!ok) {
        fprintf(stderr, "FAIL  playback did not resume after %s\n", stage);
        (*failures)++;
    }
    return ok;
}

int main(int argc, char **argv)
{
    // Re-executed as a child to hold the device from a separate process. Taking hog mode
    // from within this process would prove nothing: Core Audio hands the device straight
    // back to its existing owner, and mpv runs in this very process.
    if (argc > 1 && !strcmp(argv[1], "--hold")) {
        AudioDeviceID held = find_device(argc > 2 ? argv[2] : "D10s");
        if (!held)
            return 2;
        pid_t self = getpid();
        AudioObjectPropertyAddress a = addr(kAudioDevicePropertyHogMode,
                                            kAudioObjectPropertyScopeGlobal);
        if (AudioObjectSetPropertyData(held, &a, 0, NULL, sizeof(self), &self) != noErr)
            return 2;
        for (;;)
            pause();
    }

    if (argc < 3) {
        fprintf(stderr, "usage: %s <libmpv> <file> [device-name]\n", argv[0]);
        return 2;
    }
    const char *name = argc > 3 ? argv[3] : "D10s";

    AudioDeviceID device = find_device(name);
    if (!device) {
        fprintf(stderr, "SKIP  no device matching '%s'\n", name);
        return 77;
    }
    AudioStreamID stream = output_stream(device);
    // mpv's --audio-device takes the UID, so look it up rather than making the caller
    // find it: the name is the only thing a person reliably knows.
    char *uid = string_prop(device, kAudioDevicePropertyDeviceUID);
    if (!uid) {
        fprintf(stderr, "FAIL  could not read the UID of '%s'\n", name);
        return 2;
    }
    printf("device: %s (%s)\n", name, uid);
    AudioStreamBasicDescription found_as = physical_format(stream);
    describe("as found:", &found_as);

    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) {
        fprintf(stderr, "FAIL  %s\n", dlerror());
        return 2;
    }
#define LOAD(n) typeof(n) *n##_fn = dlsym(library, #n)
    LOAD(mpv_create);
    LOAD(mpv_set_option_string);
    LOAD(mpv_initialize);
    LOAD(mpv_command);
    LOAD(mpv_terminate_destroy);
    typeof(mpv_request_log_messages) *request_log_fn =
        dlsym(library, "mpv_request_log_messages");
    set_property_fn = dlsym(library, "mpv_set_property_string");
    get_property_fn = dlsym(library, "mpv_get_property_string");
    wait_event_fn = dlsym(library, "mpv_wait_event");
    free_fn = dlsym(library, "mpv_free");

    mpv_handle *mpv = mpv_create_fn();
    char audio_device[512];
    snprintf(audio_device, sizeof(audio_device), "coreaudio/%s", uid);
    const char *options[][2] = {
        {"config", "no"},
        {"load-scripts", "no"},
        {"vo", "null"},
        {"vid", "no"},
        {"ao", "coreaudio"},
        {"audio-device", audio_device},
        {"audio-exclusive", "yes"},
        {"coreaudio-change-physical-format", "yes"},
        {"volume", "100"},
    };
    for (int n = 0; n < sizeof(options) / sizeof(options[0]); n++)
        mpv_set_option_string_fn(mpv, options[n][0], options[n][1]);
    if (mpv_initialize_fn(mpv) < 0) {
        fprintf(stderr, "FAIL  mpv_initialize\n");
        return 2;
    }

    int failures = 0;
    request_log_fn(mpv, "info");
    const char *command[] = {"loadfile", argv[2], NULL};
    mpv_command_fn(mpv, command);
    pump(mpv, 3);

    char *ao_name = get_property_fn(mpv, "current-ao");
    printf("\nexclusive: ao=%s\n", ao_name ?: "?");
    free_fn(ao_name);
    AudioStreamBasicDescription exclusive_as = physical_format(stream);
    describe("during exclusive:", &exclusive_as);
    playback_advances(mpv, "exclusive start", &failures);

    // The switch IINA performs when exclusive mode is turned off mid-playback.
    printf("\nswitching to shared output\n");
    set_property_fn(mpv, "audio-exclusive", "no");
    pump(mpv, 3);

    ao_name = get_property_fn(mpv, "current-ao");
    printf("  ao=%s\n", ao_name ?: "?");
    if (!ao_name || strcmp(ao_name, "coreaudio")) {
        fprintf(stderr, "FAIL  expected the shared coreaudio output, got %s\n",
                ao_name ?: "none");
        failures++;
    }
    free_fn(ao_name);

    AudioStreamBasicDescription shared_as = physical_format(stream);
    describe("during shared:", &shared_as);
    // A shared stream must be mixable; the system mixer cannot feed a non-mixable one and
    // the result is the bursting the user hears.
    if (shared_as.mFormatFlags & NON_MIXABLE) {
        fprintf(stderr, "FAIL  shared output is running on a non-mixable stream\n");
        failures++;
    } else {
        printf("PASS  shared output runs on a mixable stream\n");
    }
    playback_advances(mpv, "switch to shared", &failures);

    // Turning exclusive mode on is the step that broke: the output could fail to take the
    // device or to install its format and carry on regardless, playing samples built for
    // a format the device was never put into. Watch for it saying so.
    printf("\nswitching back to exclusive\n");
    set_property_fn(mpv, "audio-exclusive", "yes");
    pump(mpv, 3);
    ao_name = get_property_fn(mpv, "current-ao");
    printf("  ao=%s\n", ao_name ?: "?");
    bool exclusive_now = ao_name && !strcmp(ao_name, "coreaudio_exclusive");
    free_fn(ao_name);

    AudioStreamBasicDescription reexclusive_as = physical_format(stream);
    describe("during exclusive again:", &reexclusive_as);
    // Whichever output won, the stream it is running on has to match it: exclusive output
    // on a mixable stream means the format change was refused and the output kept going.
    if (exclusive_now && !(reexclusive_as.mFormatFlags & NON_MIXABLE)) {
        fprintf(stderr,
                "FAIL  exclusive output is running on a stream it did not install\n");
        failures++;
    } else {
        printf("PASS  output and stream format agree\n");
    }
    playback_advances(mpv, "switch to exclusive", &failures);

    // Changing the output driver itself, which is the other switch the settings expose.
    printf("\nswitching driver to avfoundation\n");
    set_property_fn(mpv, "audio-exclusive", "no");
    set_property_fn(mpv, "ao", "avfoundation");
    pump(mpv, 4);
    ao_name = get_property_fn(mpv, "current-ao");
    printf("  ao=%s\n", ao_name ?: "?");
    free_fn(ao_name);
    playback_advances(mpv, "switch to avfoundation", &failures);

    printf("\nswitching driver back to coreaudio\n");
    set_property_fn(mpv, "ao", "coreaudio");
    pump(mpv, 4);
    ao_name = get_property_fn(mpv, "current-ao");
    printf("  ao=%s\n", ao_name ?: "?");
    free_fn(ao_name);
    playback_advances(mpv, "switch to coreaudio", &failures);

    // The case that actually bursts: something else already owns the device when
    // exclusive mode is turned on. Holding it from here reproduces a second player, or
    // this player's own previous output not yet let go of. Exclusive output cannot
    // reprogram a device it does not own, and carrying on regardless is what produced
    // noise; falling back to the shared output is the correct outcome.
    printf("\nturning exclusive on while the device is owned elsewhere\n");
    pid_t holder = fork();
    if (holder == 0) {
        execl(argv[0], argv[0], "--hold", name, (char *)NULL);
        _exit(2);
    }
    sleep(2);
    pid_t owner = -1;
    get_prop(device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
             &owner, sizeof(owner));
    if (holder <= 0 || owner != holder) {
        printf("  could not hand the device to another process, skipping this stage\n");
        if (holder > 0)
            kill(holder, SIGTERM);
    } else {
        printf("  device now owned by pid %d\n", owner);
        set_property_fn(mpv, "audio-exclusive", "yes");
        pump(mpv, 4);
        ao_name = get_property_fn(mpv, "current-ao");
        AudioStreamBasicDescription contended_as = physical_format(stream);
        printf("  ao=%s\n", ao_name ?: "?");
        describe("while owned elsewhere:", &contended_as);
        bool claims_exclusive = ao_name && !strcmp(ao_name, "coreaudio_exclusive");
        free_fn(ao_name);
        if (claims_exclusive) {
            fprintf(stderr,
                    "FAIL  exclusive output opened on a device it does not own\n");
            failures++;
        } else {
            printf("PASS  fell back instead of pretending to own the device\n");
        }
        // No assertion on playback here: hog mode locks every other process out of the
        // device, so nothing can come out of it until the owner lets go. What matters is
        // that the output did not claim the device, and that it recovers below.
        printf("  (no audio is possible while another process owns the device)\n");

        // Handing the device back must let exclusive output take it, so a moment of
        // contention does not cost the user exclusive mode for the rest of the session.
        kill(holder, SIGTERM);
        waitpid(holder, NULL, 0);
        sleep(1);
        set_property_fn(mpv, "audio-exclusive", "no");
        pump(mpv, 2);
        set_property_fn(mpv, "audio-exclusive", "yes");
        pump(mpv, 4);
        ao_name = get_property_fn(mpv, "current-ao");
        printf("  ao after the device was handed back=%s\n", ao_name ?: "?");
        bool recovered = ao_name && !strcmp(ao_name, "coreaudio_exclusive");
        free_fn(ao_name);
        if (!recovered) {
            fprintf(stderr, "FAIL  exclusive output did not recover\n");
            failures++;
        } else {
            printf("PASS  exclusive output recovered once the device was free\n");
        }
        playback_advances(mpv, "device handed back", &failures);
        set_property_fn(mpv, "audio-exclusive", "no");
        pump(mpv, 2);
    }

    mpv_terminate_destroy_fn(mpv);
    sleep(2);

    AudioStreamBasicDescription after_as = physical_format(stream);
    printf("\n");
    describe("after quit:", &after_as);

    // Exclusive output hogs the device; letting go of it again is what lets everything
    // else, including this player's own shared output, use the device afterwards. A hog
    // left behind cannot even be cleared by the process that set it once it has exited.
    pid_t hog = -1;
    get_prop(device, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
             &hog, sizeof(hog));
    printf("  %-28s %d\n", "hog owner after quit:", hog);
    if (hog != -1) {
        fprintf(stderr, "FAIL  device left hogged by pid %d\n", hog);
        failures++;
    } else {
        printf("PASS  device is no longer hogged\n");
    }

    if (after_as.mFormatFlags & NON_MIXABLE) {
        fprintf(stderr, "FAIL  device left non-mixable, other apps will burst\n");
        failures++;
    } else {
        printf("PASS  device left in a mixable format\n");
    }

    // A handful of reloads across five output switches is expected; a runaway count means
    // the output is chasing its own format change and playback cannot start.
    printf("output reload requests: %d\n", reload_requests);
    if (reload_requests > 5) {
        fprintf(stderr, "FAIL  output reloaded %d times, it is reacting to itself\n",
                reload_requests);
        failures++;
    } else {
        printf("PASS  output settled instead of reloading in a loop\n");
    }

    // Rebuilding an output drops whatever was queued, so a handful of underruns across
    // this many switches is expected. A stream of them is the device being fed late or
    // wrongly, which is what a burst of noise is.
    printf("device underruns: %d\n", underruns);
    if (underruns > 8) {
        fprintf(stderr, "FAIL  %d device underruns, the device is being starved\n",
                underruns);
        failures++;
    } else {
        printf("PASS  device was kept fed\n");
    }

    dlclose(library);
    printf("\noutput-switching check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
