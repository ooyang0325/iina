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
#include <unistd.h>

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

static void check_filter(mpv_handle *mpv, const char *name, const char *filter,
                         int *failures)
{
    if (set_property_fn(mpv, "af", filter) < 0) {
        fprintf(stderr, "FAIL  could not set %s\n", name);
        (*failures)++;
        return;
    }
    resumes(mpv, name, failures);
    char *active = get_property_fn(mpv, "af");
    bool installed = active && active[0];
    free_fn(active);
    if (!installed) {
        fprintf(stderr, "FAIL  %s failed during initialization\n", name);
        (*failures)++;
        return;
    }
    set_property_fn(mpv, "af", "");
    active = get_property_fn(mpv, "af");
    bool removed = !active || !active[0];
    free_fn(active);
    if (!removed) {
        fprintf(stderr, "FAIL  %s was not removed\n", name);
        (*failures)++;
    }
}

static void put_le16(FILE *file, unsigned value)
{
    fputc(value, file);
    fputc(value >> 8, file);
}

static void put_le32(FILE *file, unsigned value)
{
    put_le16(file, value);
    put_le16(file, value >> 16);
}

static bool write_impulse_response(const char *path)
{
    FILE *file = fopen(path, "wb");
    if (!file)
        return false;
    const unsigned samples = 4800;
    fwrite("RIFF", 1, 4, file);
    put_le32(file, 36 + samples * 2);
    fwrite("WAVEfmt ", 1, 8, file);
    put_le32(file, 16);
    put_le16(file, 1);
    put_le16(file, 1);
    put_le32(file, 48000);
    put_le32(file, 96000);
    put_le16(file, 2);
    put_le16(file, 16);
    fwrite("data", 1, 4, file);
    put_le32(file, samples * 2);
    put_le16(file, 32767);
    for (unsigned n = 1; n < samples; n++)
        put_le16(file, 0);
    return fclose(file) == 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <libmpv> [file]\n", argv[0]);
        return 2;
    }
    // A generated tone keeps the check self-contained; any decodable file works too.
    const char *file = argc > 2 ? argv[2]
                                : "av://lavfi:sine=frequency=440:duration=600,"
                                  "aformat=channel_layouts=stereo";

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

    const char *dsp[][2] = {
        {"DSP headroom", "lavfi=[volume=volume=-3dB:precision=double]"},
        {"DSP parametric EQ",
         "lavfi=[equalizer=frequency=1000:gain=-3:width_type=q:width=1:"
         "channels=all:precision=f64]"},
        {"DSP imported AutoEQ",
         "lavfi=[volume=volume=-6dB:precision=double,"
         "equalizer=frequency=105:width_type=q:width=1.2:gain=-3:precision=f64,"
         "lowshelf=frequency=120:width_type=q:width=0.7:gain=1.5:precision=f64]"},
        {"DSP imported GraphicEQ",
         "lavfi=[firequalizer=gain='cubic_interpolate(f)':"
         "gain_entry='entry(20,-10.1);entry(1000,0);entry(19871,-3.5)']"},
        {"DSP dynamic EQ",
         "lavfi=[adynamicequalizer=dfrequency=1000:dqfactor=1:threshold=50:"
         "tfrequency=1000:tqfactor=1:mode=cutabove:tftype=bell:ratio=2:"
         "range=6:attack=20:release=200:precision=double]"},
        {"DSP convolution",
         "lavfi=[aevalsrc=1:d=0.1[ir];[in][ir]afir=dry=0:wet=1:"
         "irnorm=1:precision=double[out]]"},
        {"DSP crossfeed",
         "lavfi=[crossfeed=strength=0.2:range=0.5:slope=0.5:"
         "level_in=0.9:level_out=1]"},
        {"DSP 2.1 bass management",
         "lavfi=[[in]acrossover=split=80:order=4th:precision=double[low][high];"
         "[low]pan=mono|c0=0.5*c0+0.5*c1,volume=volume=0dB:precision=double[sub];"
         "[high]volume=volume=0dB:precision=double[mains];"
         "[mains][sub]join=inputs=2:channel_layout=2.1:"
         "map=0.FL-FL|0.FR-FR|1.FC-LFE[out]]"},
        {"DSP speaker matrix", "lavfi=[pan=stereo|c0=c0|c1=c1]"},
        {"DSP speaker alignment", "lavfi=[adelay=delays=0|0:all=false]"},
        {"DSP stereo correction",
         "lavfi=[stereotools=mode=lr>lr:slev=1:balance_out=0:"
         "phasel=false:phaser=false:phase=0:delay=0]"},
        {"DSP safety limiter",
         "lavfi=[alimiter=limit=0.891251:attack=5:release=50:"
         "level=false:latency=true]"},
    };
    for (int n = 0; n < sizeof(dsp) / sizeof(dsp[0]); n++)
        check_filter(mpv, dsp[n][0], dsp[n][1], &failures);

    char ir_path[256];
    snprintf(ir_path, sizeof(ir_path), "/tmp/IINA DSP IR %d.wav", getpid());
    if (write_impulse_response(ir_path)) {
        char filter[1024];
        snprintf(filter, sizeof(filter),
                 "lavfi=[amovie=filename=%s[ir];[in][ir]afir=dry=0:wet=1:"
                 "irnorm=1:precision=double[out]]", ir_path);
        check_filter(mpv, "DSP convolution file", filter, &failures);
        unlink(ir_path);
    } else {
        fprintf(stderr, "FAIL  could not create convolution impulse response\n");
        failures++;
    }

    mpv_terminate_destroy_fn(mpv);
    dlclose(library);
    printf("option-switching check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
