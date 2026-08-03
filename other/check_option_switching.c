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
#include <sys/stat.h>
#include <unistd.h>

static typeof(mpv_wait_event) *wait_event_fn;
static typeof(mpv_get_property_string) *get_property_fn;
static typeof(mpv_set_property_string) *set_property_fn;
static typeof(mpv_free) *free_fn;
static typeof(mpv_create) *mpv_create_fn;
static typeof(mpv_set_option_string) *mpv_set_option_string_fn;
static typeof(mpv_initialize) *mpv_initialize_fn;
static typeof(mpv_command) *mpv_command_fn;
static typeof(mpv_terminate_destroy) *mpv_terminate_destroy_fn;
static typeof(mpv_request_log_messages) *mpv_request_log_messages_fn;

// mpv accepts an "af" value and reports it back before libavfilter has initialized the
// graph. When init then fails, mpv drops the filter, logs the failure and keeps playing --
// so "set returned 0", "af reads back non-empty" and "playback resumed" are all still true
// for a filter that never ran. The only signal that survives is the log, so watch it.
static int filter_errors;
static int audio_unit_configured;

static void pump(mpv_handle *mpv, double seconds)
{
    for (double t = 0; t < seconds; t += 0.05) {
        mpv_event *event = wait_event_fn(mpv, 0.05);
        if (!event || event->event_id != MPV_EVENT_LOG_MESSAGE)
            continue;
        const char *text = ((mpv_event_log_message *)event->data)->text;
        if (text && (strstr(text, "Audio filter initialized failed") ||
                     strstr(text, "parsing the filter graph failed")))
            filter_errors++;
        if (text && strstr(text, "Audio Unit") &&
            (strstr(text, "Could not") || strstr(text, "does not support") ||
             strstr(text, "not installed") || strstr(text, "render failed") ||
             strstr(text, "Invalid")))
            filter_errors++;
        if (text && strstr(text, "Audio Unit") && strstr(text, "channels") &&
            strstr(text, "latency"))
            audio_unit_configured++;
    }
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
    int errors_before = filter_errors;
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
    // The property says the filter is there. Only the log says whether it works.
    if (filter_errors > errors_before) {
        fprintf(stderr, "FAIL  %s was accepted but its filter graph failed to "
                        "initialize\n", name);
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

static bool render_pcm(const char *path, const char *filter)
{
    mpv_handle *mpv = mpv_create_fn();
    if (!mpv)
        return false;

    const char *options[][2] = {
        {"config", "no"},
        {"load-scripts", "no"},
        {"vo", "null"},
        {"vid", "no"},
        {"ao", "pcm"},
        {"ao-pcm-file", path},
        {"ao-pcm-waveheader", "no"},
        {"audio-format", "float"},
    };
    for (int n = 0; n < sizeof(options) / sizeof(options[0]); n++)
        mpv_set_option_string_fn(mpv, options[n][0], options[n][1]);
    if (mpv_initialize_fn(mpv) < 0) {
        mpv_terminate_destroy_fn(mpv);
        return false;
    }
    if (filter && set_property_fn(mpv, "af", filter) < 0) {
        mpv_terminate_destroy_fn(mpv);
        return false;
    }

    const char *command[] = {
        "loadfile",
        "av://lavfi:sine=frequency=997:duration=0.25,"
        "aformat=sample_fmts=fltp:channel_layouts=stereo",
        NULL
    };
    mpv_command_fn(mpv, command);
    bool ended = false;
    for (int n = 0; n < 200 && !ended; n++)
        ended = wait_event_fn(mpv, 0.05)->event_id == MPV_EVENT_END_FILE;
    mpv_terminate_destroy_fn(mpv);
    return ended;
}

static bool files_equal(const char *left, const char *right)
{
    FILE *a = fopen(left, "rb");
    FILE *b = fopen(right, "rb");
    if (!a || !b) {
        if (a) fclose(a);
        if (b) fclose(b);
        return false;
    }
    bool equal = true;
    unsigned char x[4096], y[4096];
    while (equal) {
        size_t nx = fread(x, 1, sizeof(x), a);
        size_t ny = fread(y, 1, sizeof(y), b);
        equal = nx == ny && memcmp(x, y, nx) == 0;
        if (!nx || nx != sizeof(x))
            break;
    }
    fclose(a);
    fclose(b);
    return equal;
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
#define LOAD(n) n##_fn = dlsym(library, #n)
    LOAD(mpv_create);
    LOAD(mpv_set_option_string);
    LOAD(mpv_initialize);
    LOAD(mpv_command);
    LOAD(mpv_terminate_destroy);
    LOAD(mpv_request_log_messages);
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
    mpv_request_log_messages_fn(mpv, "info");

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
        {"audio-resample-engine", "r8brain"},
        {"audio-resample-engine", "swr"},
        {"audio-samplerate", "0"},
        {"dovi-level5-mode", "crop"},
        {"dovi-level5-mode", "mask"},
        {"coreaudio-pcm-to-dsd", "dsd64"},
        {"coreaudio-pcm-to-dsd", "dsd128"},
        {"coreaudio-pcm-to-dsd", "off"},
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

    char au_state[256];
    snprintf(au_state, sizeof(au_state), "/tmp/IINA Audio Unit %d.aupreset",
             getpid());
    char au_filter[1024];
    snprintf(au_filter, sizeof(au_filter),
             "@iina_au_check:audiounit=component=61756678627061736170706c:"
             "state=%%%zu%%%s:bypass=yes", strlen(au_state), au_state);
    int au_errors = filter_errors;
    if (set_property_fn(mpv, "af", au_filter) < 0) {
        fprintf(stderr, "FAIL  could not add Audio Unit effect\n");
        failures++;
    } else {
        resumes(mpv, "Audio Unit bypass", &failures);
        pump(mpv, 1);
        if (filter_errors > au_errors || !audio_unit_configured) {
            fprintf(stderr, "FAIL  Audio Unit did not configure\n");
            failures++;
        }

        const char *enable[] = {
            "af-command", "iina_au_check", "set-bypass", "no", NULL
        };
        if (mpv_command_fn(mpv, enable) < 0)
            failures++, fprintf(stderr, "FAIL  could not enable Audio Unit\n");
        else
            resumes(mpv, "Audio Unit enabled", &failures);

        const char *save[] = {
            "af-command", "iina_au_check", "save-state", au_state, NULL
        };
        struct stat state_info;
        if (mpv_command_fn(mpv, save) < 0 ||
            stat(au_state, &state_info) < 0 || state_info.st_size == 0) {
            failures++;
            fprintf(stderr, "FAIL  Audio Unit preset was not saved\n");
        }

        set_property_fn(mpv, "af", "");
        if (set_property_fn(mpv, "af", au_filter) < 0)
            failures++, fprintf(stderr, "FAIL  Audio Unit preset did not reload\n");
        else
            resumes(mpv, "Audio Unit preset reload", &failures);
        set_property_fn(mpv, "af", "");
        unlink(au_state);
    }

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

    char plain_pcm[256], bypass_pcm[256];
    snprintf(plain_pcm, sizeof(plain_pcm), "/tmp/iina-au-plain-%d.pcm", getpid());
    snprintf(bypass_pcm, sizeof(bypass_pcm), "/tmp/iina-au-bypass-%d.pcm", getpid());
    const char *bypass =
        "audiounit=component=61756678627061736170706c:bypass=yes";
    bool bypass_equal = render_pcm(plain_pcm, NULL) &&
                        render_pcm(bypass_pcm, bypass) &&
                        files_equal(plain_pcm, bypass_pcm);
    if (!bypass_equal) {
        failures++;
        fprintf(stderr, "FAIL  Audio Unit bypass changed PCM samples (%s, %s)\n",
                plain_pcm, bypass_pcm);
    } else {
        unlink(plain_pcm);
        unlink(bypass_pcm);
    }

    mpv_terminate_destroy_fn(mpv);
    dlclose(library);
    printf("option-switching check %s\n", failures ? "FAILED" : "PASSED");
    return failures ? 1 : 0;
}
