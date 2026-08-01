#!/usr/bin/env bash
#
# Run the regression checks that need a real DAC attached.
#
# These cannot run on a hosted CI machine: they take exclusive control of a device,
# reprogram its stream format and listen to what comes back out. Run them on the machine
# the DAC is plugged into, before releasing anything that touches audio output.
#
# Usage:  other/run_hardware_checks.sh [device-name] [file]
#
#   device-name  substring of the output device to test, default "D10s"
#   file         a DSD file to play; without one the DoP check generates DSD silence and
#                the switching check is skipped
#
# Expects other/build_dv_atmos_deps.sh to have run first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$REPO_ROOT/deps/build/prefix"
LIBMPV="$REPO_ROOT/deps/build/src/mpv/build/libmpv.2.dylib"
DEVICE="${1:-D10s}"
FILE="${2:-}"

if [ ! -f "$LIBMPV" ]; then
    echo "missing $LIBMPV -- run other/build_dv_atmos_deps.sh first" >&2
    exit 2
fi

failures=0
run() {
    local name="$1"; shift
    printf '\n=== %s ===\n' "$name"
    "$@"
    local status=$?
    if [ "$status" -eq 0 ]; then
        printf '=== %s: PASS ===\n' "$name"
    elif [ "$status" -eq 77 ]; then
        printf '=== %s: SKIPPED (no device) ===\n' "$name"
    else
        printf '=== %s: FAIL ===\n' "$name"
        failures=$((failures + 1))
    fi
}

# DoP reaches the DAC as an exact integer carrier, the device is locked exclusively, and
# its original formats are handed back afterwards.
cc "$REPO_ROOT/other/check_dop_hardware.c" -I"$REPO_ROOT/deps/include" \
   -framework CoreAudio -framework CoreFoundation -o "$PREFIX/check_dop_hardware"
if [ -n "$FILE" ]; then
    run "DoP output" "$PREFIX/check_dop_hardware" "$LIBMPV" "$FILE"
else
    run "DoP output" "$PREFIX/check_dop_hardware" "$LIBMPV"
fi

# Switching between exclusive and shared output, and between output drivers, must keep
# playback running and must never leave the device on a stream the system mixer cannot
# feed. A non-mixable stream left behind is heard as bursts of noise by every application.
cc "$REPO_ROOT/other/check_output_switching.c" -I"$REPO_ROOT/deps/include" \
   -framework CoreAudio -framework CoreFoundation -o "$PREFIX/check_output_switching"
if [ -n "$FILE" ]; then
    run "output switching" "$PREFIX/check_output_switching" "$LIBMPV" "$FILE" "$DEVICE"
else
    printf '\n=== output switching: SKIPPED (needs a file to play) ===\n'
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    echo "all hardware checks passed"
else
    echo "$failures hardware check(s) failed"
fi
exit $((failures == 0 ? 0 : 1))
