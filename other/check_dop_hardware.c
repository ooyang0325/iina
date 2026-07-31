#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <mpv/client.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void put32(FILE *file, uint32_t value)
{
    for (int n = 0; n < 4; n++)
        fputc(value >> (n * 8), file);
}

static void put64(FILE *file, uint64_t value)
{
    for (int n = 0; n < 8; n++)
        fputc(value >> (n * 8), file);
}

static bool write_dsd_silence(const char *path, int seconds)
{
    const int channels = 2;
    const int bytes_per_second = 2822400 / 8;
    int blocks = (seconds * bytes_per_second + 4095) / 4096;
    uint64_t channel_bytes = (uint64_t)blocks * 4096;
    uint64_t data_bytes = channel_bytes * channels;

    FILE *file = fopen(path, "wb");
    if (!file)
        return false;

    fwrite("DSD ", 1, 4, file);
    put64(file, 28);
    put64(file, 28 + 52 + 12 + data_bytes);
    put64(file, 0);

    fwrite("fmt ", 1, 4, file);
    put64(file, 52);
    put32(file, 1);
    put32(file, 0);
    put32(file, 2);
    put32(file, channels);
    put32(file, 2822400);
    put32(file, 8);
    put64(file, channel_bytes * 8);
    put32(file, 4096);
    put32(file, 0);

    fwrite("data", 1, 4, file);
    put64(file, 12 + data_bytes);
    unsigned char silence[4096];
    memset(silence, 0x69, sizeof(silence));
    for (int block = 0; block < blocks; block++)
        for (int channel = 0; channel < channels; channel++)
            fwrite(silence, 1, sizeof(silence), file);

    return fclose(file) == 0;
}

static void address(AudioObjectPropertyAddress *a,
                    AudioObjectPropertySelector selector,
                    AudioObjectPropertyScope scope)
{
    *a = (AudioObjectPropertyAddress){
        selector, scope, kAudioObjectPropertyElementMain,
    };
}

static bool get_property(AudioObjectID object,
                         AudioObjectPropertySelector selector,
                         AudioObjectPropertyScope scope,
                         void *value, UInt32 size)
{
    AudioObjectPropertyAddress a;
    address(&a, selector, scope);
    return AudioObjectGetPropertyData(object, &a, 0, NULL, &size, value) == noErr;
}

static int volume_elements(AudioDeviceID device,
                           AudioObjectPropertyElement elements[2])
{
    AudioObjectPropertyAddress a;
    address(&a, kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput);
    if (AudioObjectHasProperty(device, &a)) {
        elements[0] = kAudioObjectPropertyElementMain;
        return 1;
    }
    int count = 0;
    for (int channel = 1; channel <= 2; channel++) {
        a.mElement = channel;
        if (AudioObjectHasProperty(device, &a))
            elements[count++] = channel;
    }
    return count;
}

static bool device_volume(AudioDeviceID device, float *volume, bool set)
{
    AudioObjectPropertyElement elements[2];
    int count = volume_elements(device, elements);
    if (!count)
        return false;
    AudioObjectPropertyAddress a;
    address(&a, kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput);
    if (set) {
        for (int n = 0; n < count; n++) {
            a.mElement = elements[n];
            if (AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof(*volume),
                                           volume) != noErr)
                return false;
        }
    } else {
        *volume = 0;
        for (int n = 0; n < count; n++) {
            float channel = 0;
            a.mElement = elements[n];
            if (!get_property(device, kAudioDevicePropertyVolumeScalar,
                              kAudioDevicePropertyScopeOutput, &channel,
                              sizeof(channel)))
                return false;
            *volume = fmaxf(*volume, channel);
        }
    }
    return true;
}

static char *string_property(AudioObjectID object,
                             AudioObjectPropertySelector selector)
{
    CFStringRef value = NULL;
    if (!get_property(object, selector, kAudioObjectPropertyScopeGlobal,
                      &value, sizeof(value)) || !value)
        return NULL;

    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
                                                     kCFStringEncodingUTF8) + 1;
    char *result = calloc(size, 1);
    CFStringGetCString(value, result, size, kCFStringEncodingUTF8);
    CFRelease(value);
    return result;
}

static AudioDeviceID find_d10s(void)
{
    AudioObjectPropertyAddress a;
    address(&a, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL,
                                       &size) != noErr)
        return 0;
    AudioDeviceID *devices = malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size,
                               devices);
    AudioDeviceID result = 0;
    int count = size / sizeof(*devices);
    for (int n = 0; n < count; n++) {
        char *name = string_property(devices[n], kAudioObjectPropertyName);
        if (name && strstr(name, "D10s"))
            result = devices[n];
        free(name);
        if (result)
            break;
    }
    free(devices);
    return result;
}

static void set_default_device(AudioObjectPropertySelector selector,
                               AudioDeviceID device)
{
    AudioObjectPropertyAddress a;
    address(&a, selector, kAudioObjectPropertyScopeGlobal);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                               sizeof(device), &device);
}

static bool exact_dop_carrier(AudioStreamID stream, int rate, int channels)
{
    AudioObjectPropertyAddress a;
    address(&a, kAudioStreamPropertyAvailablePhysicalFormats,
            kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(stream, &a, 0, NULL, &size) != noErr)
        return false;

    AudioStreamRangedDescription *formats = malloc(size);
    if (AudioObjectGetPropertyData(stream, &a, 0, NULL, &size, formats) != noErr) {
        free(formats);
        return false;
    }

    bool found = false;
    int count = size / sizeof(*formats);
    for (int n = 0; n < count; n++) {
        AudioStreamBasicDescription f = formats[n].mFormat;
        AudioValueRange r = formats[n].mSampleRateRange;
        if (f.mFormatID == kAudioFormatLinearPCM &&
            rate >= r.mMinimum && rate <= r.mMaximum &&
            f.mChannelsPerFrame == channels &&
            f.mBytesPerFrame == 4 * channels &&
            f.mFramesPerPacket == 1 &&
            (f.mBitsPerChannel == 24 || f.mBitsPerChannel == 32) &&
            (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
            !(f.mFormatFlags & (kAudioFormatFlagIsFloat |
                                kAudioFormatFlagIsBigEndian |
                                kAudioFormatFlagIsNonInterleaved))) {
            found = true;
            break;
        }
    }
    free(formats);
    return found;
}

static bool physical_carrier_is_live(const AudioStreamBasicDescription *f)
{
    return f->mFormatID == kAudioFormatLinearPCM &&
           f->mSampleRate == 176400 &&
           f->mChannelsPerFrame == 2 &&
           f->mBytesPerFrame == 8 &&
           (f->mBitsPerChannel == 24 || f->mBitsPerChannel == 32) &&
           (f->mFormatFlags & kAudioFormatFlagIsSignedInteger) &&
           !(f->mFormatFlags & kAudioFormatFlagIsFloat);
}

static bool virtual_bridge_is_live(const AudioStreamBasicDescription *f)
{
    bool exact_sample =
        (f->mFormatFlags & kAudioFormatFlagIsFloat) ||
        (f->mFormatFlags & kAudioFormatFlagIsSignedInteger);
    return f->mFormatID == kAudioFormatLinearPCM &&
           f->mSampleRate == 176400 &&
           f->mChannelsPerFrame == 2 &&
           f->mBytesPerFrame == 8 &&
           (f->mBitsPerChannel == 24 || f->mBitsPerChannel == 32) &&
           exact_sample;
}

static bool same_format(const AudioStreamBasicDescription *a,
                        const AudioStreamBasicDescription *b)
{
    return a->mFormatID == b->mFormatID &&
           a->mFormatFlags == b->mFormatFlags &&
           a->mSampleRate == b->mSampleRate &&
           a->mBitsPerChannel == b->mBitsPerChannel &&
           a->mBytesPerFrame == b->mBytesPerFrame &&
           a->mChannelsPerFrame == b->mChannelsPerFrame;
}

static void print_format(const char *label,
                         const AudioStreamBasicDescription *f)
{
    printf("%s: %.0f Hz, %u-bit integer, flags 0x%x, %u B/frame, %u ch\n",
           label, f->mSampleRate, f->mBitsPerChannel, f->mFormatFlags,
           f->mBytesPerFrame, f->mChannelsPerFrame);
}

int main(int argc, char **argv)
{
    const char *library_path = argc > 1 ? argv[1] : "deps/lib/libmpv.2.dylib";
    const char *file_path =
        argc > 2 ? argv[2] : "/tmp/iina-dop-silence.dsf";
    bool generated_silence = argc <= 2;
    int failures = 0;
    float saved_volume = 1;
    bool testing_volume = false;

    AudioDeviceID device = find_d10s();
    if (!device) {
        fprintf(stderr, "FAIL  Topping D10s not found\n");
        return 2;
    }

    AudioObjectPropertyAddress a;
    address(&a, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr ||
        size < sizeof(AudioStreamID)) {
        fprintf(stderr, "FAIL  output device has no stream\n");
        return 2;
    }
    AudioStreamID stream = 0;
    size = sizeof(stream);
    AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &stream);

    char *name = string_property(device, kAudioObjectPropertyName);
    char *uid = string_property(device, kAudioDevicePropertyDeviceUID);
    printf("device: %s\nuid: %s\n", name ?: "?", uid ?: "?");
    if (!name || !strstr(name, "D10s")) {
        fprintf(stderr, "FAIL  default output is not the Topping D10s\n");
        failures++;
    }
    if (!uid || !exact_dop_carrier(stream, 176400, 2)) {
        fprintf(stderr, "FAIL  device has no exact 176.4 kHz integer DoP carrier\n");
        failures++;
    } else {
        printf("PASS  exact 176.4 kHz integer DoP carrier is available\n");
    }
    if (failures)
        goto done;

    if (device_volume(device, &saved_volume, false)) {
        float reduced = 0.5;
        testing_volume = device_volume(device, &reduced, true);
    }

    AudioStreamBasicDescription original_physical = {0};
    AudioStreamBasicDescription original_virtual = {0};
    get_property(stream, kAudioStreamPropertyPhysicalFormat,
                 kAudioObjectPropertyScopeGlobal, &original_physical,
                 sizeof(original_physical));
    get_property(stream, kAudioStreamPropertyVirtualFormat,
                 kAudioObjectPropertyScopeGlobal, &original_virtual,
                 sizeof(original_virtual));

    if (generated_silence && !write_dsd_silence(file_path, 20)) {
        fprintf(stderr, "FAIL  could not create DSD-silence sample\n");
        failures++;
        goto done;
    }

    void *library = dlopen(library_path, RTLD_NOW);
    if (!library) {
        fprintf(stderr, "FAIL  cannot load %s: %s\n", library_path, dlerror());
        failures++;
        goto done;
    }

#define LOAD(name) typeof(name) *name##_fn = dlsym(library, #name)
    LOAD(mpv_create);
    LOAD(mpv_set_option_string);
    LOAD(mpv_initialize);
    LOAD(mpv_command);
    LOAD(mpv_request_log_messages);
    LOAD(mpv_wait_event);
    LOAD(mpv_get_property_string);
    LOAD(mpv_set_property_string);
    LOAD(mpv_free);
    LOAD(mpv_terminate_destroy);

    mpv_handle *mpv = mpv_create_fn();
    if (!mpv) {
        fprintf(stderr, "FAIL  mpv_create\n");
        failures++;
        dlclose(library);
        goto done;
    }

    char audio_device[1024];
    snprintf(audio_device, sizeof(audio_device), "coreaudio/%s", uid);
    const char *options[][2] = {
        {"config", "no"},
        {"load-scripts", "no"},
        {"input-default-bindings", "no"},
        {"vo", "null"},
        {"ao", "coreaudio"},
        {"audio-device", audio_device},
        {"audio-exclusive", "yes"},
        {"audio-spdif", "dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar"},
        {"volume", "100"},
    };
    for (int n = 0; n < sizeof(options) / sizeof(options[0]); n++)
        mpv_set_option_string_fn(mpv, options[n][0], options[n][1]);

    if (mpv_initialize_fn(mpv) < 0) {
        fprintf(stderr, "FAIL  mpv_initialize\n");
        failures++;
        mpv_terminate_destroy_fn(mpv);
        dlclose(library);
        goto done;
    }
    mpv_request_log_messages_fn(mpv, "trace");

    const char *command[] = {"loadfile", file_path, NULL};
    mpv_command_fn(mpv, command);

    char *format = NULL;
    char *rate = NULL;
    char *ao = NULL;
    for (int n = 0; n < 200; n++) {
        mpv_event *event = mpv_wait_event_fn(mpv, 0.05);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            if (!strcmp(message->prefix, "ad") ||
                !strncmp(message->prefix, "ao", 2) ||
                !strcmp(message->prefix, "cplayer") ||
                !strcmp(message->prefix, "lavf"))
                fprintf(stderr, "[%s] %s", message->prefix, message->text);
        }
        format = mpv_get_property_string_fn(mpv, "audio-out-params/format");
        rate = mpv_get_property_string_fn(mpv, "audio-out-params/samplerate");
        ao = mpv_get_property_string_fn(mpv, "current-ao");
        if (format && rate && ao)
            break;
        mpv_free_fn(format);
        mpv_free_fn(rate);
        mpv_free_fn(ao);
        format = rate = ao = NULL;
        usleep(50000);
    }
    for (int n = 0; n < 100; n++) {
        mpv_event *event = mpv_wait_event_fn(mpv, 0.01);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *message = event->data;
            if (!strcmp(message->prefix, "ad") ||
                !strncmp(message->prefix, "ao", 2) ||
                !strcmp(message->prefix, "cplayer") ||
                !strcmp(message->prefix, "lavf"))
                fprintf(stderr, "[%s] %s", message->prefix, message->text);
        }
    }
    mpv_set_property_string_fn(mpv, "volume", "25");
    sleep(1);

    AudioStreamBasicDescription physical = {0};
    AudioStreamBasicDescription virtual = {0};
    pid_t hog = -1;
    get_property(stream, kAudioStreamPropertyPhysicalFormat,
                 kAudioObjectPropertyScopeGlobal, &physical, sizeof(physical));
    get_property(stream, kAudioStreamPropertyVirtualFormat,
                 kAudioObjectPropertyScopeGlobal, &virtual, sizeof(virtual));
    get_property(device, kAudioDevicePropertyHogMode,
                 kAudioObjectPropertyScopeGlobal, &hog, sizeof(hog));
    float active_volume = 1;
    bool read_active_volume = device_volume(device, &active_volume, false);

    printf("mpv output: ao=%s, format=%s, rate=%s Hz\n",
           ao ?: "?", format ?: "?", rate ?: "?");
    print_format("physical", &physical);
    print_format("virtual", &virtual);
    printf("hog owner: %d, test process: %d\n", hog, getpid());

    if (format && !strcmp(format, "dop") && rate &&
        !strcmp(rate, "176400") && ao && strstr(ao, "coreaudio")) {
        printf("PASS  mpv is delivering DoP at 176.4 kHz\n");
    } else {
        fprintf(stderr, "FAIL  mpv fell back instead of opening DoP\n");
        failures++;
    }
    if (physical_carrier_is_live(&physical) &&
        virtual_bridge_is_live(&virtual)) {
        printf("PASS  Core Audio virtual stream preserves the integer carrier exactly\n");
    } else {
        fprintf(stderr, "FAIL  Core Audio stream formats cannot preserve DoP\n");
        failures++;
    }
    if (hog == getpid()) {
        printf("PASS  the D10s is exclusively locked by this process\n");
    } else {
        fprintf(stderr, "FAIL  exclusive hog mode was not acquired\n");
        failures++;
    }
    if (testing_volume && (!read_active_volume || active_volume < 0.999f)) {
        fprintf(stderr, "FAIL  DoP did not force hardware volume to unity\n");
        failures++;
    } else if (testing_volume) {
        printf("PASS  DoP forced hardware volume to unity\n");
    }

    if (!failures) {
        printf("PLAY  transmitting %s for 12 seconds",
               generated_silence ? "DSD64 silence" : file_path);
        fflush(stdout);
        for (int n = 0; n < 12; n++) {
            sleep(1);
            printf(".");
            fflush(stdout);
        }
        puts("");
    }

    mpv_free_fn(format);
    mpv_free_fn(rate);
    mpv_free_fn(ao);
    mpv_terminate_destroy_fn(mpv);
    dlclose(library);
    sleep(1);

    AudioStreamBasicDescription restored_physical = {0};
    AudioStreamBasicDescription restored_virtual = {0};
    get_property(stream, kAudioStreamPropertyPhysicalFormat,
                 kAudioObjectPropertyScopeGlobal, &restored_physical,
                 sizeof(restored_physical));
    get_property(stream, kAudioStreamPropertyVirtualFormat,
                 kAudioObjectPropertyScopeGlobal, &restored_virtual,
                 sizeof(restored_virtual));
    if (same_format(&original_physical, &restored_physical) &&
        same_format(&original_virtual, &restored_virtual)) {
        printf("PASS  original DAC formats restored after playback\n");
    } else {
        fprintf(stderr, "FAIL  original DAC formats were not restored\n");
        failures++;
        print_format("was physical", &original_physical);
        print_format("now physical", &restored_physical);
        print_format("was virtual", &original_virtual);
        print_format("now virtual", &restored_virtual);
    }
    if (testing_volume) {
        float restored_volume = 0;
        if (!device_volume(device, &restored_volume, false) ||
            fabsf(restored_volume - 0.5f) > 0.02f) {
            fprintf(stderr,
                    "FAIL  original hardware volume was not restored (%.3f)\n",
                    restored_volume);
            failures++;
        } else {
            printf("PASS  original hardware volume restored after DoP\n");
        }
    }

done:
    if (testing_volume)
        device_volume(device, &saved_volume, true);
    set_default_device(kAudioHardwarePropertyDefaultOutputDevice, device);
    set_default_device(kAudioHardwarePropertyDefaultSystemOutputDevice, device);
    if (generated_silence)
        remove(file_path);
    free(name);
    free(uid);
    printf("%s\n", failures ? "DoP hardware check FAILED"
                            : "DoP hardware check PASSED");
    return failures ? 1 : 0;
}
