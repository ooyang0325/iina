#!/usr/bin/env bash
#
# Build the Dolby Vision / Dolby Atmos dependency stack for IINA.
#
# IINA itself only contains the player. This script builds the four pinned
# dependencies below and stages the result into deps/.
#
#   FFmpeg     dovi_split bitstream filter -- splits the Profile 7 enhancement
#              layer out of the base stream. Master only, in no release.
#   libplacebo Dolby Vision L2/L8 creative trims, and FEL composition.
#   libsacd    Scarlet Book/SACD ISO parsing and track extraction.
#   mpv        libmpv 'gpu-next' render backend (the legacy 'gpu' backend
#              discards Dolby Vision metadata before it reaches the renderer),
#              BL+EL frame pairing, Atmos object rendering via liborender, and
#              E-AC-3 passthrough to AVFoundation, plus DSD over PCM output.
#
# Usage:  other/build_dv_atmos_deps.sh [--prefix DIR] [--jobs N] [--mpegh]
#
#   --mpegh  Add Fraunhofer's MPEG-H 3D Audio decoder. FFmpeg classifies
#            libmpeghdec as nonfree, so this forces --enable-nonfree, and the
#            resulting binaries CANNOT BE REDISTRIBUTED. It is also mutually
#            exclusive with FFmpeg's GPL components, so the build loses
#            librubberband, libdvdnav and libdvdread. Use it for a local build
#            only, never for anything published.
#
# Requires: Xcode command line tools, and from Homebrew:
#   meson ninja pkg-config nasm libass luajit uchardet libarchive libbluray
#   little-cms2 dav1d ffmpeg (for its own dependencies)
#   libsoxr rubberband libopenmpt jpeg-xl libssh libdvdnav libdvdread libdvdcss

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$REPO_ROOT/deps/build/prefix"
SRC="$REPO_ROOT/deps/build/src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# MPEG-H 3D Audio is off by default. FFmpeg classifies libmpeghdec as nonfree,
# alongside libfdk_aac and decklink, so enabling it forces --enable-nonfree,
# which makes the resulting binaries unredistributable, and --disable-gpl,
# which drops librubberband, libdvdnav and libdvdread. Fine for a local build,
# not for anything published. See --help.
MPEGH=0

# Pinned revisions. These are the exact trees the shipped build was made from;
# the playback projects move fast, so floating them will eventually break.
FFMPEG_URL="https://github.com/ooyang0325/FFmpeg.git"
FFMPEG_REV="0fca971eca"
PLACEBO_URL="https://github.com/ooyang0325/libplacebo.git"
PLACEBO_REV="67032e7140fcd6978f553d12013c5c647b15f103"
MPV_URL="https://github.com/ooyang0325/mpv.git"
MPV_REV="089a6a35e"
SACD_URL="https://github.com/Sound-Linux-More/sacd.git"
SACD_REV="6cfc988eca603c770788b3fd489b192ae5d264e5"
MPEGHDEC_URL="https://github.com/Fraunhofer-IIS/mpeghdec.git"
MPEGHDEC_REV="4448b69"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --jobs)   JOBS="$2"; shift 2 ;;
        --mpegh)  MPEGH=1; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

BREW="$(brew --prefix)"
export PKG_CONFIG="${PKG_CONFIG:-$BREW/bin/pkg-config}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig:$BREW/lib/pkgconfig"

mkdir -p "$SRC" "$PREFIX"

# Clone at a pinned revision, or reset an existing clone to it.
fetch() {
    local name="$1" url="$2" rev="$3" dir="$SRC/$1"
    if [ ! -d "$dir/.git" ]; then
        echo ">> cloning $name"
        git clone --filter=blob:none "$url" "$dir"
    fi
    echo ">> $name -> $rev"
    git -C "$dir" fetch --quiet origin "$rev" 2>/dev/null || git -C "$dir" fetch --quiet origin
    git -C "$dir" -c advice.detachedHead=false checkout --quiet "$rev"
}

# ---- Fraunhofer MPEG-H 3D Audio decoder -------------------------------------
# FFmpeg has no MPEG-H decoder of its own, so this supplies one. Only built
# when --mpegh is passed, because FFmpeg treats it as nonfree; see the note at
# the top of this file. Fraunhofer's own licence permits redistribution in
# binary form without fee provided the licence text travels with it and the
# source stays available free of charge, which deps/licenses/ and the pinned
# URL above cover. It grants no patent licence, separately from the copyright.
if [ "$MPEGH" = 1 ]; then
    fetch mpeghdec "$MPEGHDEC_URL" "$MPEGHDEC_REV"
    if [ ! -f "$PREFIX/share/pkgconfig/mpeghdec.pc" ]; then
        echo ">> building libmpeghdec"
        # MacPorts ships a cmake that cannot run on this machine, so be explicit.
        ( cd "$SRC/mpeghdec" && "$BREW/bin/cmake" -S . -B build \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
          && "$BREW/bin/cmake" --build build -j"$JOBS" \
          && "$BREW/bin/cmake" --install build )
    fi
    mkdir -p "$REPO_ROOT/deps/licenses"
    cp "$SRC/mpeghdec/LICENSE.txt" "$REPO_ROOT/deps/licenses/mpeghdec-LICENSE.txt"
fi

# ---- SACD ISO parser ---------------------------------------------------------
# Only the parser and media reader are needed. FFmpeg already supplies the DSD
# and DST decoders, and mpv owns playback, seeking, and track selection.
fetch sacd "$SACD_URL" "$SACD_REV"
SACD_STAMP="$PREFIX/.sacd-build-stamp"
SACD_HASH="$(cat "$REPO_ROOT/other/sacd_bridge.cpp" "$REPO_ROOT/other/sacd_bridge.h" |
             shasum -a 256 | cut -d' ' -f1)"
if [ ! -f "$PREFIX/lib/libsacd.0.dylib" ] || \
   [ "$(cat "$SACD_STAMP" 2>/dev/null)" != "$SACD_REV-$SACD_HASH" ]; then
    echo ">> building libsacd"
    mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
    clang++ -std=c++17 -O2 -dynamiclib -mmacosx-version-min=26.0 \
        -I"$SRC/sacd/libsacd" -I"$REPO_ROOT/other" \
        "$SRC/sacd/libsacd/sacd_media.cpp" \
        "$SRC/sacd/libsacd/scarletbook.cpp" \
        "$SRC/sacd/libsacd/sacd_disc.cpp" \
        "$REPO_ROOT/other/sacd_bridge.cpp" \
        -liconv \
        -Wl,-install_name,@rpath/libsacd.0.dylib \
        -o "$PREFIX/lib/libsacd.0.dylib"
    ln -sf libsacd.0.dylib "$PREFIX/lib/libsacd.dylib"
    cp "$REPO_ROOT/other/sacd_bridge.h" "$PREFIX/include/"
    cat > "$PREFIX/lib/pkgconfig/sacd.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: sacd
Description: SACD ISO parser bridge
Version: 1
Libs: -L\${libdir} -lsacd
Cflags: -I\${includedir}
EOF
    echo "$SACD_REV-$SACD_HASH" > "$SACD_STAMP"
fi
mkdir -p "$REPO_ROOT/deps/licenses"
cp "$SRC/sacd/LICENSE" "$REPO_ROOT/deps/licenses/libsacd-LICENSE.txt"

echo ">> checking SACD ISO parser"
clang++ -std=c++17 "$REPO_ROOT/other/check_sacd_iso.cpp" \
    -I"$REPO_ROOT/other" -I"$SRC/sacd/libsacd" \
    -L"$PREFIX/lib" -lsacd -o "$PREFIX/check_sacd_iso"
DYLD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/check_sacd_iso"

# ---- FFmpeg -----------------------------------------------------------------
# Beyond the Dolby Vision work, these switches turn on decoders, filters and
# protocols FFmpeg can build but does not by default. They are what the DSP,
# resampling, disc and format phases of the roadmap are built on.
FFMPEG_OPTS=(
    --prefix="$PREFIX"
    --enable-shared --disable-static --enable-version3
    --disable-programs --disable-doc --disable-debug
    --enable-libdav1d --enable-videotoolbox --enable-audiotoolbox
    --enable-libsoxr        # high quality sample rate conversion
    --enable-libopenmpt     # tracker modules (.mod, .xm, .it, .s3m)
    --enable-libjxl         # JPEG XL
    --enable-libssh         # sftp:// protocol
)
if [ "$MPEGH" = 1 ]; then
    echo "!! building a NONFREE, UNREDISTRIBUTABLE FFmpeg for MPEG-H 3D Audio"
    echo "!! this build has no rubberband and no DVD support"
    FFMPEG_OPTS+=(--enable-nonfree --enable-libmpeghdec)
else
    FFMPEG_OPTS+=(
        --enable-gpl
        --enable-librubberband  # time stretching and pitch shifting
        --enable-libdvdnav --enable-libdvdread  # DVD demuxing
    )
fi
fetch ffmpeg "$FFMPEG_URL" "$FFMPEG_REV"
# Rebuild when the option set changes, not just when the tree is missing, or
# editing the switches above would silently do nothing.
FFMPEG_STAMP="$PREFIX/.ffmpeg-configure-stamp"
FFMPEG_HASH="$(printf '%s\n' "$FFMPEG_REV" "${FFMPEG_OPTS[@]}" | shasum -a 256 | cut -d' ' -f1)"
if [ ! -f "$PREFIX/lib/libavcodec.dylib" ] || \
   [ "$(cat "$FFMPEG_STAMP" 2>/dev/null)" != "$FFMPEG_HASH" ]; then
    echo ">> building FFmpeg"
    ( cd "$SRC/ffmpeg" && ./configure "${FFMPEG_OPTS[@]}" \
        --extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib" \
      && make -j"$JOBS" && make install )
    echo "$FFMPEG_HASH" > "$FFMPEG_STAMP"
fi

echo ">> checking raw DST-to-DSD decoding"
"$PKG_CONFIG" --cflags --libs libavcodec libavutil >/dev/null
cc "$REPO_ROOT/other/check_dst_raw.c" \
   $("$PKG_CONFIG" --cflags --libs libavcodec libavutil) \
   -o "$PREFIX/check_dst_raw"
DYLD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/check_dst_raw"

# ---- libplacebo -------------------------------------------------------------
fetch libplacebo "$PLACEBO_URL" "$PLACEBO_REV"
if [ ! -f "$PREFIX/lib/pkgconfig/libplacebo.pc" ]; then
    echo ">> building libplacebo"
    ( cd "$SRC/libplacebo" && git submodule update --init --recursive \
      && meson setup build --prefix="$PREFIX" --buildtype=release \
            -Dtests=false -Ddemos=false -Dxxhash=disabled \
            -Dc_args="-I$BREW/include" -Dcpp_args="-I$BREW/include" \
      && meson compile -C build && meson install -C build )
fi

# ---- mpv --------------------------------------------------------------------
fetch mpv "$MPV_URL" "$MPV_REV"
echo ">> building libmpv"
# mpv gates dvdnav behind its own -Dgpl, and rubberband needs the library the
# nonfree FFmpeg build drops, so both follow the same switch as above.
if [ "$MPEGH" = 1 ]; then
    MPV_GPL_OPTS=(-Dgpl=false -Drubberband=disabled -Ddvdnav=disabled -Dsacd=disabled)
else
    MPV_GPL_OPTS=(-Drubberband=enabled -Ddvdnav=enabled -Dsacd=enabled)
fi
( cd "$SRC/mpv" && rm -rf build \
  && meson setup build --prefix="$PREFIX" --buildtype=release \
        -Dlibmpv=true -Dcplayer=false -Dorender=enabled -Dtests=true \
        -Dlua=enabled -Dlibarchive=enabled -Dlibbluray=enabled \
        "${MPV_GPL_OPTS[@]}" \
  && meson compile -C build )

# ---- stage into deps/ -------------------------------------------------------
echo ">> staging headers"
mkdir -p "$REPO_ROOT/deps/include/mpv"
cp "$SRC/mpv/include/mpv/"*.h "$REPO_ROOT/deps/include/mpv/"
for d in libavcodec libavformat libavutil libswscale; do
    mkdir -p "$REPO_ROOT/deps/include/$d"
    cp "$PREFIX/include/$d/"*.h "$REPO_ROOT/deps/include/$d/"
done

echo ">> staging dylibs"
rm -rf "$REPO_ROOT/deps/lib"
# The legacy staging helper resolves direct @rpath dependencies beside libmpv.
# Put the parser there; the closure pass below still rewrites and verifies it.
cp "$PREFIX/lib/libsacd.0.dylib" "$SRC/mpv/build/"
ruby "$REPO_ROOT/other/change_lib_dependencies.rb" "$BREW" \
     "$SRC/mpv/build/libmpv.2.dylib"

# change_lib_dependencies.rb only rewrites Homebrew-prefixed dependencies, so
# anything from our own prefix (FFmpeg, libplacebo) is still absolute. Walk the
# graph to closure and make every non-system reference @rpath-relative.
python3 - "$REPO_ROOT/deps/lib" "$PREFIX/lib" "$BREW/lib" <<'PY'
import os, subprocess, shutil, sys
staged, search = sys.argv[1], sys.argv[2:]
os.chdir(staged)

def deps(f):
    out = subprocess.run(['otool', '-L', f], capture_output=True, text=True)
    # Skip the first line (the file name) and the second (the library's own ID).
    return [l.strip().split(' ')[0] for l in out.stdout.splitlines()[1:] if l.strip()]

def bundle(src, base):
    shutil.copy2(src, base)
    os.chmod(base, 0o755)
    subprocess.run(['install_name_tool', '-id', '@rpath/' + base, base], capture_output=True)
    print('   bundled', base)

changed, rounds = True, 0
while changed and rounds < 16:
    changed, rounds = False, rounds + 1
    for f in sorted(os.listdir('.')):
        if not f.endswith('.dylib'):
            continue
        for d in deps(f):
            base = os.path.basename(d)
            if d.startswith(('/usr/lib', '/System')):
                continue
            # A library built with @rpath install names of its own, such as libjxl
            # referring to libjxl_cms, needs its dependency bundled too even though the
            # reference itself is already relative and needs no rewriting.
            if d.startswith('@rpath'):
                if not os.path.exists(base):
                    found = next((os.path.join(p, base) for p in search
                                  if os.path.exists(os.path.join(p, base))), None)
                    if not found:
                        print('!! missing on disk:', d)
                        continue
                    bundle(found, base)
                    changed = True
                continue
            if not os.path.exists(base):
                if not os.path.exists(d):
                    print('!! missing on disk:', d)
                    continue
                bundle(d, base)
            subprocess.run(['install_name_tool', '-change', d, '@rpath/' + base, f],
                           capture_output=True)
            changed = True

# Anything still absolute, or referred to but never bundled, would fail to load
# out of the .app bundle. The second case is the one that bit libjxl_cms: the
# reference looked fine because it was already @rpath, but the file was absent.
bad = 0
present = set(os.listdir('.'))
for f in sorted(os.listdir('.')):
    if not f.endswith('.dylib'):
        continue
    for d in deps(f):
        if not d.startswith(('@rpath', '/usr/lib', '/System')):
            print('!! unrelocated:', f, '->', d)
            bad += 1
        elif d.startswith('@rpath') and os.path.basename(d) not in present:
            print('!! not bundled:', f, '->', d)
            bad += 1
sys.exit(1 if bad else 0)
PY

cat <<EOF

Done. deps/ is staged:
  headers  deps/include/
  dylibs   deps/lib/  ($(ls "$REPO_ROOT"/deps/lib/*.dylib 2>/dev/null | wc -l | tr -d ' ') libraries)

The FFmpeg soname versions are pinned in the Xcode project's OTHER_LDFLAGS
(-lavcodec.NN and friends). If you move FFmpeg to a revision that bumps a
major soname, update them to match or the link will fail.

Now build IINA:
  xcodebuild -project iina.xcodeproj -scheme iina -configuration Release \\
             ARCHS=arm64 build
EOF
