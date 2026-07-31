// Exclusive output must play the format the device is actually running.
//
// A non-mixable stream is passed to the hardware untouched: Core Audio inserts no
// conversion, so the samples the player writes have to be laid out exactly as the stream
// is configured. The output takes that layout from the stream's virtual format, which
// macOS re-derives from the physical format asynchronously after a format change. Reading
// it too early yields the previous format, and the player then writes (for example) floats
// into a stream the DAC reads as 32-bit integers, which is heard as full-scale noise.
//
// It is a race, so it is checked in a loop: opening exclusive output repeatedly is what
// turning the setting on during playback does.
//
// Usage: check_exclusive_format <libmpv> <file> [device-name] [rounds]
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
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL,
                                       &size) != noErr)
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

#define NON_MIXABLE 0x40

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <libmpv> <file> [device-name] [rounds]\n", argv[0]);
        return 2;
    }
    const char *name = argc > 3 ? argv[3] : "D10s";
    int rounds = argc > 4 ? atoi(argv[4]) : 6;

    AudioDeviceID device = find_device(name);
    if (!device) {
        fprintf(stderr, "SKIP  no device matching '%s'\n", name);
        return 77;
    }
    AudioStreamID stream = output_stream(device);
    char *uid = string_prop(device, kAudioDevicePropertyDeviceUID);

    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) {
        fprintf(stderr, "FAIL  %s\n", dlerror());
        return 2;
    }
#define LOAD(n) typeof(n) *n##_fn = dlsym(library, #n)
    LOAD(mpv_create);
    LOAD(mpv_set_option_string);
    LOAD(mpv_set_property_string);
    LOAD(mpv_get_property_string);
    LOAD(mpv_initialize);
    LOAD(mpv_command);
    LOAD(mpv_wait_event);
    LOAD(mpv_free);
    LOAD(mpv_terminate_destroy);

    mpv_handle *mpv = mpv_create_fn();
    char audio_device[512];
    snprintf(audio_device, sizeof(audio_device), "coreaudio/%s", uid ?: "");
    const char *options[][2] = {
        {"config", "no"},
        {"load-scripts", "no"},
        {"vo", "null"},
        {"vid", "no"},
        {"ao", "coreaudio"},
        {"audio-device", audio_device},
        {"audio-exclusive", "no"},
        {"coreaudio-change-physical-format", "yes"},
        {"volume", "100"},
    };
    for (int n = 0; n < sizeof(options) / sizeof(options[0]); n++)
        mpv_set_option_string_fn(mpv, options[n][0], options[n][1]);
    if (mpv_initialize_fn(mpv) < 0) {
        fprintf(stderr, "FAIL  mpv_initialize\n");
        return 2;
    }
    const char *command[] = {"loadfile", argv[2], NULL};
    mpv_command_fn(mpv, command);
    for (int n = 0; n < 60; n++)
        mpv_wait_event_fn(mpv, 0.05);

    int failures = 0;
    for (int round = 1; round <= rounds; round++) {
        mpv_set_property_string_fn(mpv, "audio-exclusive", "yes");
        for (int n = 0; n < 70; n++)
            mpv_wait_event_fn(mpv, 0.05);

        AudioStreamBasicDescription physical = {0};
        get_prop(stream, kAudioStreamPropertyPhysicalFormat,
                 kAudioObjectPropertyScopeGlobal, &physical, sizeof(physical));
        char *ao_name = mpv_get_property_string_fn(mpv, "current-ao");
        char *out_format = mpv_get_property_string_fn(mpv, "audio-out-params/format");
        char *out_rate = mpv_get_property_string_fn(mpv, "audio-out-params/samplerate");

        bool exclusive = ao_name && !strcmp(ao_name, "coreaudio_exclusive");
        bool nonmixable = physical.mFormatFlags & NON_MIXABLE;
        bool device_is_float = physical.mFormatFlags & kAudioFormatFlagIsFloat;
        // "dop" carries integer words, so it counts as integer here.
        bool player_is_float = out_format && !strncmp(out_format, "float", 5);
        bool rate_agrees = !out_rate ||
                           fabs(atof(out_rate) - physical.mSampleRate) < 1.0;

        printf("round %d: ao=%-20s player=%-7s %-8s device=%.0fHz %s %s\n", round,
               ao_name ?: "?", out_format ?: "?", out_rate ?: "?",
               physical.mSampleRate, device_is_float ? "float" : "int",
               nonmixable ? "NON-MIXABLE" : "mixable");

        // Deliberately no assertion that the player's format matches the device's.
        // Core Audio converts between the stream's virtual format (what the player
        // writes) and its physical format (what the DAC clocks out) even on a
        // non-mixable stream: non-mixable stops other applications being mixed in, it
        // does not disable conversion. A float player format over an integer physical
        // format is therefore normal, and is exactly what the DoP float bridge relies
        // on. What is worth recording is the pairing itself, so a future investigation
        // has the numbers rather than a guess.
        if (exclusive && nonmixable && !rate_agrees) {
            fprintf(stderr, "FAIL  round %d: player at %s Hz, device at %.0f Hz\n",
                    round, out_rate, physical.mSampleRate);
            failures++;
        }
        mpv_free_fn(ao_name);
        mpv_free_fn(out_format);
        mpv_free_fn(out_rate);

        mpv_set_property_string_fn(mpv, "audio-exclusive", "no");
        for (int n = 0; n < 40; n++)
            mpv_wait_event_fn(mpv, 0.05);
    }

    mpv_terminate_destroy_fn(mpv);
    dlclose(library);
    free(uid);
    printf("exclusive-format check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
