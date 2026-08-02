#include <mpv/client.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void set_option(mpv_handle *mpv, const char *name, const char *value)
{
    if (mpv_set_option_string(mpv, name, value) < 0) {
        fprintf(stderr, "FAIL  could not set %s=%s\n", name, value);
        exit(2);
    }
}

static void print_property(mpv_handle *mpv, const char *name)
{
    char *value = mpv_get_property_string(mpv, name);
    printf("%s=%s\n", name, value ? value : "(unavailable)");
    mpv_free(value);
}

static bool property_is(mpv_handle *mpv, const char *name, const char *expected)
{
    char *value = mpv_get_property_string(mpv, name);
    bool matches = value && strcmp(value, expected) == 0;
    if (!matches)
        fprintf(stderr, "FAIL  %s=%s, expected %s\n", name,
                value ? value : "(unavailable)", expected);
    mpv_free(value);
    return matches;
}

static bool property_positive(mpv_handle *mpv, const char *name)
{
    char *value = mpv_get_property_string(mpv, name);
    bool positive = value && strtoll(value, NULL, 10) > 0;
    if (!positive)
        fprintf(stderr, "FAIL  %s=%s, expected a positive count\n", name,
                value ? value : "(unavailable)");
    mpv_free(value);
    return positive;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <Dolby Vision Profile 7 file>\n", argv[0]);
        return 2;
    }

    mpv_handle *mpv = mpv_create();
    if (!mpv)
        return 2;
    set_option(mpv, "config", "no");
    set_option(mpv, "load-scripts", "no");
    set_option(mpv, "ao", "null");
    set_option(mpv, "vo", "null");
    set_option(mpv, "hwdec", "no");
    set_option(mpv, "start", "103");
    set_option(mpv, "pause", "no");
    if (mpv_initialize(mpv) < 0)
        return 2;
    mpv_request_log_messages(mpv, "info");

    const char *load[] = {"loadfile", argv[1], NULL};
    if (mpv_command(mpv, load) < 0)
        return 2;

    bool ready = false;
    for (int n = 0; n < 300 && !ready; n++) {
        mpv_event *event = mpv_wait_event(mpv, 0.1);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            if (strstr(log->text, "Dolby Vision") ||
                strstr(log->text, "dovi_split") ||
                strstr(log->text, "enhancement"))
                fprintf(stderr, "%s: %s", log->prefix, log->text);
        }
        char *position = mpv_get_property_string(mpv, "time-pos");
        ready = position && atof(position) >= 104;
        mpv_free(position);
    }

    const char *properties[] = {
        "time-pos",
        "current-tracks/video/dolby-vision-profile",
        "current-tracks/video/dolby-vision-enhancement-layer",
        "video-frame-info/dolby-vision-mode",
        "video-frame-info/dolby-vision-composition",
        "video-frame-info/dolby-vision-rpu",
        "video-frame-info/dolby-vision-el-paired",
        "video-frame-info/dolby-vision-el-format",
        "video-frame-info/dolby-vision-el-pairs",
        "video-frame-info/dolby-vision-el-misses",
        "video-frame-info/dolby-vision-el-late",
        "video-params/w",
        "video-params/h",
        "video-params/dw",
        "video-params/dh",
    };
    for (int n = 0; n < sizeof(properties) / sizeof(properties[0]); n++)
        print_property(mpv, properties[n]);

    bool ok = ready;
    ok &= property_is(mpv, "video-frame-info/dolby-vision-mode", "FEL");
    ok &= property_is(mpv, "video-frame-info/dolby-vision-composition", "active");
    ok &= property_is(mpv, "video-frame-info/dolby-vision-el-paired", "yes");
    ok &= property_positive(mpv, "video-frame-info/dolby-vision-el-pairs");
    ok &= property_is(mpv, "video-frame-info/dolby-vision-el-misses", "0");
    ok &= property_is(mpv, "video-frame-info/dolby-vision-el-late", "0");
    ok &= property_is(mpv, "video-params/dw", "3840");
    ok &= property_is(mpv, "video-params/dh", "1520");

    mpv_terminate_destroy(mpv);
    printf("FEL Level 5 playback check %s\n", ok ? "PASSED" : "FAILED");
    return ok ? 0 : 1;
}
