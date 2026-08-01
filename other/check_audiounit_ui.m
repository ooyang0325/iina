// Open and tear down a real Audio Unit view. Thermion exercises a JUCE custom
// Cocoa view when installed; CI falls back to Apple's generic parameter view.
#import <AudioToolbox/AudioToolbox.h>
#import <Cocoa/Cocoa.h>
#include <mpv/client.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_bool command_finished;

static void timeout(int signal)
{
    _exit(signal);
}

static void stop_app(void)
{
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
        context:nil subtype:0 data1:0 data2:0] atStart:NO];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        signal(SIGALRM, timeout);
        alarm(15);

        AudioComponentDescription thermion = {
            .componentType = kAudioUnitType_Effect,
            .componentSubType = 'T64S',
            .componentManufacturer = 'ThmN',
        };
        bool has_thermion = argc == 1 &&
                            AudioComponentFindNext(NULL, &thermion) != NULL;
        const char *component = has_thermion
            ? "617566785436345354686d4e"
            : "61756678627061736170706c";
        NSString *expected = has_thermion ? @"Thermion T-64" : @"AUBandpass";

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
        mpv_handle *mpv = mpv_create();
        if (!mpv)
            return 2;
        mpv_set_option_string(mpv, "config", "no");
        mpv_set_option_string(mpv, "load-scripts", "no");
        mpv_set_option_string(mpv, "vo", "null");
        mpv_set_option_string(mpv, "vid", "no");
        mpv_set_option_string(mpv, "ao", "null");
        if (mpv_initialize(mpv) < 0)
            return 2;

        const char *load[] = {
            "loadfile", "av://lavfi:sine=duration=30,"
            "aformat=channel_layouts=stereo", NULL
        };
        mpv_command(mpv, load);
        char filter[128];
        snprintf(filter, sizeof(filter), "@ui:audiounit=component=%s", component);
        if (mpv_set_property_string(mpv, "af", filter) < 0)
            return 2;

        __block int result = 1;
        atomic_store(&command_finished, false);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                const char *show[] = {"af-command", "ui", "show-ui", "", NULL};
                atomic_store(&command_finished, mpv_command(mpv, show) >= 0);
            });
            usleep(200000);
            char *value = mpv_get_property_string(mpv, "time-pos");
            mpv_free(value);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            bool found = false;
            for (NSWindow *window in NSApp.windows)
                found |= [window.title containsString:expected];
            result = !(atomic_load(&command_finished) && found);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                mpv_terminate_destroy(mpv);
                dispatch_async(dispatch_get_main_queue(), ^{ stop_app(); });
            });
        });
        [NSApp run];
        printf("Audio Unit native UI check %s (%s)\n",
               result ? "FAILED" : "PASSED",
               has_thermion ? "custom" : "generic");
        return result;
    }
}
