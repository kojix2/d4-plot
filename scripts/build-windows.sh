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
  ./configure --disable-libcurl --disable-shared --enable-static
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

crystal spec spec --static --link-flags="${static_libs[*]}"
crystal build src/d4-plot.cr --release --no-debug --static \
  --link-flags="${static_libs[*]} -mwindows" -o bin/d4-plot.exe

# Include upstream license texts in both portable ZIP and installer.
bash scripts/collect-licenses.sh build/licenses
mkdir -p build/licenses/htslib
cp "$htslib_dir/LICENSE" build/licenses/htslib/
cp "$htslib_dir/htscodecs/LICENSE.md" build/licenses/htslib/htscodecs-LICENSE.md
mkdir -p build/licenses/msys2
cp -R "$mingw_prefix/share/licenses/." build/licenses/msys2/
pacman -Q > build/licenses/msys2-packages.txt
