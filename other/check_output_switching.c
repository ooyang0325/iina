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
#include <string.h>
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

static void pump(mpv_handle *mpv, double seconds)
{
    for (double t = 0; t < seconds; t += 0.05) {
        mpv_event *event = wait_event_fn(mpv, 0.05);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            if (strstr(message->text, "Stream format changed"))
                reload_requests++;
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

    // And back again, which is the other half of the toggle.
    printf("\nswitching back to exclusive\n");
    set_property_fn(mpv, "audio-exclusive", "yes");
    pump(mpv, 3);
    ao_name = get_property_fn(mpv, "current-ao");
    printf("  ao=%s\n", ao_name ?: "?");
    free_fn(ao_name);
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

    mpv_terminate_destroy_fn(mpv);
    sleep(2);

    AudioStreamBasicDescription after_as = physical_format(stream);
    printf("\n");
    describe("after quit:", &after_as);
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

    dlclose(library);
    printf("\noutput-switching check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
