#!/usr/bin/env bash
#
# Run every regression check that does not need audio hardware.
#
# These exist because each one is a bug that shipped once: a build losing a decoder, an
# SACD image decoding to noise, DST silently coming out as PCM, DoP words carrying the
# wrong markers, or changing an audio setting stopping playback until the user seeks.
#
# Usage:  other/run_checks.sh
#
# Expects other/build_dv_atmos_deps.sh to have run first, since everything here links
# against the staged libraries.
#
# The checks that do need hardware are not run here; see other/run_hardware_checks.sh.

# -e matters here: the compiles below are not wrapped in run(), so without it a failed
# build left the previous run's binary in $PREFIX and run() happily executed that instead,
# reporting PASS for source that no longer compiles.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$REPO_ROOT/deps/build/prefix"
SRC="$REPO_ROOT/deps/build/src"
BREW="$(brew --prefix)"
export PKG_CONFIG="${PKG_CONFIG:-$BREW/bin/pkg-config}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$BREW/lib/pkgconfig"

failures=0
run() {
    local name="$1"; shift
    printf '\n=== %s ===\n' "$name"
    if "$@"; then
        printf '=== %s: PASS ===\n' "$name"
    else
        printf '=== %s: FAIL ===\n' "$name"
        failures=$((failures + 1))
    fi
}

# The build turned out the way it was asked to: every decoder, filter and protocol the
# player depends on is actually compiled in.
run "build features" "$REPO_ROOT/other/check_build_features.sh"

# Scarlet Book parsing: areas, tracks, durations, and a playback timeline that only ever
# moves forwards. Overlapping timestamps here were heard as bursts of noise.
clang++ -std=c++17 "$REPO_ROOT/other/check_sacd_iso.cpp" \
    -I"$REPO_ROOT/other" -I"$SRC/sacd/libsacd" \
    -L"$PREFIX/lib" -lsacd -o "$PREFIX/check_sacd_iso"
run "SACD ISO parsing" env DYLD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/check_sacd_iso"

# DST must be able to hand back the raw DSD it decoded, or SACD discs that use it cannot
# reach a DoP capable DAC unconverted.
cc "$REPO_ROOT/other/check_dst_raw.c" \
   $("$PKG_CONFIG" --cflags --libs libavcodec libavutil) \
   -o "$PREFIX/check_dst_raw"
run "raw DST to DSD" env DYLD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/check_dst_raw"

# AutoEQ and REW export the same Equalizer APO text format. Keep its small parser independent
# from AppKit so malformed presets cannot silently generate a partial filter chain.
swiftc "$REPO_ROOT/iina/EqualizerAPOParser.swift" "$REPO_ROOT/iina/AudiophileDSP.swift" \
    "$REPO_ROOT/other/check_equalizer_apo.swift" \
    -o "$PREFIX/check_equalizer_apo"
run "Equalizer APO import" "$PREFIX/check_equalizer_apo"

# DoP packing: marker alternation, bit order, channel interleave and packet boundaries.
run "mpv unit tests" meson test -C "$SRC/mpv/build" --print-errorlogs

# Changing an audio setting mid-playback must not stop playback.
cc "$REPO_ROOT/other/check_option_switching.c" -I"$REPO_ROOT/deps/include" \
   -o "$PREFIX/check_option_switching"
run "audio option switching" "$PREFIX/check_option_switching" \
    "$SRC/mpv/build/libmpv.2.dylib"

printf '\n'
if [ "$failures" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$failures check(s) failed"
fi
exit $((failures == 0 ? 0 : 1))
