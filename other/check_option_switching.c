// Changing audio settings during playback must never leave playback stopped.
//
// IINA rewrites several mpv options in a row when one setting changes: turning exclusive
// mode on, for instance, changes the device, the exclusive flag and the passthrough codec
// list together. mpv's reload_audio_output() destroys the output on the first of those and
// returns early on the rest, so the replacement has to be built by the audio loop. When
// that did not happen, playback stopped dead and only seeking brought it back, which is
// exactly what a user sees as "the play button does nothing".
//
// This runs on the null output, so it needs no sound hardware and can run anywhere.
#include <assert.h>
#include <dlfcn.h>
#include <mpv/client.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static typeof(mpv_wait_event) *wait_event_fn;
static typeof(mpv_get_property_string) *get_property_fn;
static typeof(mpv_set_property_string) *set_property_fn;
static typeof(mpv_free) *free_fn;

static void pump(mpv_handle *mpv, double seconds)
{
    for (double t = 0; t < seconds; t += 0.05)
        wait_event_fn(mpv, 0.05);
}

static double time_pos(mpv_handle *mpv)
{
    char *value = get_property_fn(mpv, "time-pos");
    double result = value ? atof(value) : -1;
    free_fn(value);
    return result;
}

// Wait for playback to make progress on its own. The output is allowed to take a moment to
// come back; what is not allowed is never coming back.
static bool resumes(mpv_handle *mpv, const char *stage, int *failures)
{
    double before = time_pos(mpv);
    double after = before;
    for (int n = 0; n < 20 && !(after > before); n++) {
        pump(mpv, 0.5);
        after = time_pos(mpv);
    }
    bool ok = after > before;
    printf("  %-34s %6.2f -> %6.2f s  %s\n", stage, before, after,
           ok ? "ok" : "STALLED");
    if (!ok) {
        fprintf(stderr, "FAIL  playback did not resume after %s\n", stage);
        (*failures)++;
    }
    return ok;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <libmpv> [file]\n", argv[0]);
        return 2;
    }
    // A generated tone keeps the check self-contained; any decodable file works too.
    const char *file = argc > 2 ? argv[2]
                                : "av://lavfi:sine=frequency=440:duration=600";

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
    wait_event_fn = dlsym(library, "mpv_wait_event");
    get_property_fn = dlsym(library, "mpv_get_property_string");
    set_property_fn = dlsym(library, "mpv_set_property_string");
    free_fn = dlsym(library, "mpv_free");

    mpv_handle *mpv = mpv_create_fn();
    if (!mpv) {
        fprintf(stderr, "FAIL  mpv_create\n");
        return 2;
    }
    const char *options[][2] = {
        {"config", "no"},
        {"load-scripts", "no"},
        {"vo", "null"},
        {"vid", "no"},
        {"ao", "null"},
        {"untimed", "no"},
    };
    for (int n = 0; n < sizeof(options) / sizeof(options[0]); n++)
        mpv_set_option_string_fn(mpv, options[n][0], options[n][1]);
    if (mpv_initialize_fn(mpv) < 0) {
        fprintf(stderr, "FAIL  mpv_initialize\n");
        return 2;
    }

    int failures = 0;
    const char *command[] = {"loadfile", file, NULL};
    mpv_command_fn(mpv, command);
    pump(mpv, 2);
    resumes(mpv, "start", &failures);

    // One option at a time: each of these reloads the output on its own.
    const char *single[][2] = {
        {"audio-exclusive", "yes"},
        {"audio-exclusive", "no"},
        {"audio-samplerate", "96000"},
        {"audio-samplerate", "0"},
        {"audio-spdif", "ac3,dts"},
        {"audio-spdif", ""},
    };
    for (int n = 0; n < sizeof(single) / sizeof(single[0]); n++) {
        set_property_fn(mpv, single[n][0], single[n][1]);
        char stage[128];
        snprintf(stage, sizeof(stage), "%s=%s", single[n][0],
                 single[n][1][0] ? single[n][1] : "(empty)");
        resumes(mpv, stage, &failures);
    }

    // And the case that actually broke: several at once, the way the settings pane does
    // it, so every reload after the first one finds the output already gone.
    const char *burst[][2] = {
        {"audio-exclusive", "yes"},
        {"audio-spdif", "ac3,dts,dts-hd"},
        {"audio-samplerate", "192000"},
        {"ao", "null"},
    };
    for (int n = 0; n < sizeof(burst) / sizeof(burst[0]); n++)
        set_property_fn(mpv, burst[n][0], burst[n][1]);
    resumes(mpv, "four options changed together", &failures);

    const char *restore[][2] = {
        {"audio-exclusive", "no"},
        {"audio-spdif", ""},
        {"audio-samplerate", "0"},
    };
    for (int n = 0; n < sizeof(restore) / sizeof(restore[0]); n++)
        set_property_fn(mpv, restore[n][0], restore[n][1]);
    resumes(mpv, "settings restored together", &failures);

    mpv_terminate_destroy_fn(mpv);
    dlclose(library);
    printf("option-switching check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
