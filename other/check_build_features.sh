#!/usr/bin/env bash
#
# Assert the dependency stack was built with the features IINA expects.
#
# The build script turns on decoders, filters and protocols that FFmpeg and mpv
# can build but do not by default. A missing Homebrew package makes FFmpeg's
# configure quietly skip a switch and mpv's meson quietly fall back, so without
# this the loss only shows up as a file that will not play, long after the fact.
#
# Usage:  other/check_build_features.sh
#
# Reads the configuration headers of the built trees, so it must run after
# other/build_dv_atmos_deps.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_CFG="$REPO_ROOT/deps/build/src/ffmpeg/config_components.h"
FFMPEG_LIBS="$REPO_ROOT/deps/build/src/ffmpeg/config.h"
MPV_CFG="$REPO_ROOT/deps/build/src/mpv/build/config.h"

for f in "$FFMPEG_CFG" "$FFMPEG_LIBS" "$MPV_CFG"; do
    if [ ! -f "$f" ]; then
        echo "missing $f -- run other/build_dv_atmos_deps.sh first" >&2
        exit 2
    fi
done

failures=0
section() { printf '\n%s\n' "$1"; }

# Assert a "#define NAME 1" is present in the given header.
want() {
    local file="$1" name="$2" note="${3:-}"
    local value
    value="$(sed -n "s/^#define ${name} \([0-9]*\)$/\1/p" "$file" | head -1)"
    if [ "$value" = "1" ]; then
        printf '  ok    %-28s %s\n' "$name" "$note"
    else
        printf '  FAIL  %-28s %s\n' "$name" "${value:-absent}"
        failures=$((failures + 1))
    fi
}

ff()  { want "$FFMPEG_LIBS" "CONFIG_$1" "${2:-}"; }
ffc() { want "$FFMPEG_CFG"  "CONFIG_$1" "${2:-}"; }
mpv() { want "$MPV_CFG"     "HAVE_$1"   "${2:-}"; }

section "FFmpeg external libraries"
ff LIBDAV1D     "AV1 decoding"
ff LIBSOXR      "high quality resampling"
ff LIBRUBBERBAND "time stretch and pitch shift"
ff LIBOPENMPT   "tracker modules"
ff LIBJXL       "JPEG XL"
ff LIBSSH       "sftp:// protocol"
ff LIBDVDNAV    "DVD navigation"
ff LIBDVDREAD   "DVD reading"
ff VIDEOTOOLBOX "hardware video decoding"
ff AUDIOTOOLBOX "system audio decoders"

section "FFmpeg audio DSP (the DSP rack is built from these)"
for f in ANEQUALIZER FIREQUALIZER SUPEREQUALIZER EQUALIZER AFIR CROSSFEED \
         HEADPHONE LOUDNORM PAN CHANNELMAP ARESAMPLE ADELAY SURROUND \
         ACOMPRESSOR ALIMITER RUBBERBAND; do
    ffc "${f}_FILTER"
done

section "FFmpeg audio decoders"
for d in DSD_MSBF DSD_LSBF DSD_MSBF_PLANAR DSD_LSBF_PLANAR DST WAVPACK TAK APE \
         TTA SHORTEN ALAC FLAC OPUS QOA MLP TRUEHD DCA EAC3 AC3; do
    ffc "${d}_DECODER"
done

section "FFmpeg video decoders"
for d in VVC HEVC AV1 LIBDAV1D LIBJXL; do
    ffc "${d}_DECODER"
done

section "FFmpeg demuxers"
for d in DSF DVDVIDEO LIBOPENMPT; do
    ffc "${d}_DEMUXER"
done

section "mpv"
mpv COREAUDIO    "shared and exclusive Core Audio output"
mpv AVFOUNDATION "Dolby Atmos output"
mpv ORENDER      "object audio rendering"
mpv LIBBLURAY    "Blu-ray"
mpv DVDNAV       "DVD navigation"
mpv RUBBERBAND   "af_rubberband"
mpv LIBARCHIVE   "archives"
mpv LUA          "scripting"
mpv UCHARDET     "subtitle charset detection"

if [ "$failures" -eq 0 ]; then
    printf '\nall expected build features are present\n'
else
    printf '\n%d expected feature(s) missing\n' "$failures"
fi
exit $((failures == 0 ? 0 : 1))
