#!/usr/bin/env bash
#
# Build the Dolby Vision / Dolby Atmos dependency stack for IINA.
#
# IINA itself only contains the player. The capabilities below live in three
# other projects, none of which ship a release with them yet, so this script
# builds all three from pinned sources and stages the result into deps/.
#
#   FFmpeg     dovi_split bitstream filter -- splits the Profile 7 enhancement
#              layer out of the base stream. Master only, in no release.
#   libplacebo Dolby Vision L2/L8 creative trims, and FEL composition.
#   mpv        libmpv 'gpu-next' render backend (the legacy 'gpu' backend
#              discards Dolby Vision metadata before it reaches the renderer),
#              BL+EL frame pairing, Atmos object rendering via liborender, and
#              E-AC-3 passthrough to AVFoundation.
#
# Usage:  other/build_dv_atmos_deps.sh [--prefix DIR] [--jobs N]
#
# Requires: Xcode command line tools, and from Homebrew:
#   meson ninja pkg-config nasm libass luajit uchardet libarchive libbluray
#   little-cms2 dav1d ffmpeg (for its own dependencies)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$REPO_ROOT/deps/build/prefix"
SRC="$REPO_ROOT/deps/build/src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Pinned revisions. These are the exact trees the shipped build was made from;
# all three projects move fast, so floating them will eventually break.
FFMPEG_URL="https://github.com/FFmpeg/FFmpeg.git"
FFMPEG_REV="d43b1efd2e948f44cfac91f7a4325a3d927d6718"
PLACEBO_URL="https://github.com/ooyang0325/libplacebo.git"
PLACEBO_REV="67032e7140fcd6978f553d12013c5c647b15f103"
MPV_URL="https://github.com/ooyang0325/mpv.git"
MPV_REV="da8aab5754e3e9f5bf5d1e100cc310a9b09e62e5"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --jobs)   JOBS="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

BREW="$(brew --prefix)"
export PKG_CONFIG="${PKG_CONFIG:-$BREW/bin/pkg-config}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$BREW/opt/libarchive/lib/pkgconfig:$BREW/lib/pkgconfig"

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

# ---- FFmpeg -----------------------------------------------------------------
fetch ffmpeg "$FFMPEG_URL" "$FFMPEG_REV"
if [ ! -f "$PREFIX/lib/libavcodec.dylib" ]; then
    echo ">> building FFmpeg"
    ( cd "$SRC/ffmpeg" && ./configure --prefix="$PREFIX" \
        --enable-shared --disable-static --enable-gpl --enable-version3 \
        --disable-programs --disable-doc --disable-debug \
        --enable-libdav1d --enable-videotoolbox --enable-audiotoolbox \
        --extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib" \
      && make -j"$JOBS" && make install )
fi

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
( cd "$SRC/mpv" && rm -rf build \
  && meson setup build --prefix="$PREFIX" --buildtype=release \
        -Dlibmpv=true -Dcplayer=false -Dorender=enabled \
        -Dlua=enabled -Dlibarchive=enabled -Dlibbluray=enabled \
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
ruby "$REPO_ROOT/other/change_lib_dependencies.rb" "$BREW" \
     "$SRC/mpv/build/libmpv.2.dylib"

# change_lib_dependencies.rb only rewrites Homebrew-prefixed dependencies, so
# anything from our own prefix (FFmpeg, libplacebo) is still absolute. Walk the
# graph to closure and make every non-system reference @rpath-relative.
python3 - "$REPO_ROOT/deps/lib" <<'PY'
import os, subprocess, shutil, sys
os.chdir(sys.argv[1])

def deps(f):
    out = subprocess.run(['otool', '-L', f], capture_output=True, text=True)
    return [l.strip().split(' ')[0] for l in out.stdout.splitlines()[1:] if l.strip()]

changed, rounds = True, 0
while changed and rounds < 16:
    changed, rounds = False, rounds + 1
    for f in sorted(os.listdir('.')):
        if not f.endswith('.dylib'):
            continue
        for d in deps(f):
            if d.startswith(('@rpath', '/usr/lib', '/System')):
                continue
            base = os.path.basename(d)
            if not os.path.exists(base):
                if not os.path.exists(d):
                    print('!! missing on disk:', d)
                    continue
                shutil.copy2(d, base)
                os.chmod(base, 0o755)
                subprocess.run(['install_name_tool', '-id', '@rpath/' + base, base],
                               capture_output=True)
                print('   bundled', base)
            subprocess.run(['install_name_tool', '-change', d, '@rpath/' + base, f],
                           capture_output=True)
            changed = True

# Anything still absolute would fail to load out of the .app bundle.
bad = 0
for f in sorted(os.listdir('.')):
    if f.endswith('.dylib'):
        for d in deps(f):
            if not d.startswith(('@rpath', '/usr/lib', '/System')):
                print('!! unrelocated:', f, '->', d)
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
