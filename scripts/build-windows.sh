#!/usr/bin/env bash
set -euo pipefail

[[ ${MSYSTEM:-} == UCRT64 ]] || { echo 'Run this script in MSYS2 UCRT64.' >&2; exit 1; }
mingw_prefix=${MINGW_PREFIX:?MSYS2 must set MINGW_PREFIX}
# Pin the native library as well as the Crystal shards. Local inputs only: no
# libcurl and no remote-reference fetching in the Windows distribution.
htslib_version=1.24
htslib_dir="$PWD/build/htslib-$htslib_version"
mkdir -p build bin
if [[ ! -d $htslib_dir ]]; then
  git clone --depth 1 --branch "$htslib_version" --recurse-submodules \
    https://github.com/samtools/htslib.git "$htslib_dir"
fi
(
  cd "$htslib_dir"
  autoreconf -i
  ./configure --disable-libcurl
  make -j2 libhts.a
)
htslib_native=$(cygpath -m "$htslib_dir")
mingw_native=$(cygpath -m "$mingw_prefix/lib")
pkgconfig_dir="$PWD/build/htslib-pkgconfig"
mkdir -p "$pkgconfig_dir"
cat > "$pkgconfig_dir/htslib.pc" <<EOF
Name: htslib
Description: Local-only static HTSlib for d4-plot
Version: $htslib_version
Cflags: -I"$htslib_native"
Libs: -L"$htslib_native" -lhts
EOF
export PKG_CONFIG_PATH="$pkgconfig_dir:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_DISABLE_UNINSTALLED=1
static_libs=("-L$htslib_native" "-L$mingw_native" -Wl,--start-group -l:libhts.a)
for library in bz2 lzma z deflate regex tre intl; do
  test -f "$mingw_prefix/lib/lib$library.a"
  static_libs+=("-l:lib$library.a")
done
static_libs+=(-Wl,--end-group -lws2_32)

# Embed the application icon so portable builds and installer shortcuts share it.
windres -I assets -i assets/d4-plot.rc -o build/d4-plot-icon.o
icon_resource=$(cygpath -m "$PWD/build/d4-plot-icon.o")

if [[ ${1:-} == --guide-screenshots ]]; then
  crystal build scripts/guide-screenshots.cr --release --no-debug --static \
    --link-flags="${static_libs[*]} $icon_resource -mwindows" -o bin/guide-screenshots.exe
  exit 0
fi

# `crystal spec` has no `--static` option, so define the same compiler flag
# explicitly. Besides selecting the archives below, this prevents Windows
# foreign data symbols from being emitted as DLL imports.
crystal spec spec -D static --link-flags="${static_libs[*]}"
crystal build src/d4-plot.cr --release --no-debug --static \
  --link-flags="${static_libs[*]} $icon_resource -mwindows" -o bin/d4-plot.exe
crystal build src/d4-plot-server.cr --release --no-debug --static \
  --link-flags="${static_libs[*]}" -o bin/d4-plot-server.exe

# Include upstream license texts in both portable ZIP and installer.
license_work=$(mktemp -d "$PWD/build/package-licenses.XXXXXX")
trap 'rm -rf "$license_work"' EXIT
licenses=$license_work/licenses
bash scripts/collect-licenses.sh "$licenses"
mkdir -p "$licenses/htslib"
cp "$htslib_dir/LICENSE" "$licenses/htslib/"
cp "$htslib_dir/htscodecs/LICENSE.md" "$licenses/htslib/htscodecs-LICENSE.md"
mkdir -p "$licenses/msys2"
cp -R "$mingw_prefix/share/licenses/." "$licenses/msys2/"
pacman -Q > "$licenses/msys2-packages.txt"
rm -rf build/licenses
mv "$licenses" build/licenses
