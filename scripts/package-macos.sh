#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-macos.sh [TAG [ARCH]]

Package the already-built bin/d4-plot and bin/d4-plot-server executables
in a macOS DMG.
TAG defaults to v<version from shard.yml>.
ARCH defaults to the current Mac's architecture (arm64 or x64).

Examples:
  scripts/package-macos.sh
  scripts/package-macos.sh v0.0.5 arm64
  scripts/package-macos.sh --help
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if (( $# > 2 )); then
  usage >&2
  exit 2
fi

tag=${1:-}
if [[ -z $tag ]]; then
  package_version=$(awk '$1 == "version:" { print $2; exit }' shard.yml)
  if [[ -z $package_version ]]; then
    echo "Could not read the package version from shard.yml" >&2
    exit 1
  fi
  tag="v${package_version}"
fi

arch=${2:-}
if [[ -z $arch ]]; then
  case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64) arch=x64 ;;
    *)
      echo "Unsupported architecture; pass arm64 or x64 explicitly" >&2
      exit 1
      ;;
  esac
fi
version=${tag#v}

mkdir -p build dist
work=$(mktemp -d "$PWD/build/package-macos.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle=$work/d4-plot.app
executable=$bundle/Contents/MacOS/d4-plot
server_executable=$bundle/Contents/MacOS/d4-plot-server
disk_image="dist/d4-plot-${tag}-macos-${arch}.dmg"

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 755 bin/d4-plot "$executable"
install -m 755 bin/d4-plot-server "$server_executable"
install -m 644 LICENSE README.md "$bundle/Contents/Resources/"
crystal run scripts/make-icns.cr -- assets/d4-plot.png "$bundle/Contents/Resources/d4-plot.icns"
bash scripts/collect-licenses.sh "$bundle/Contents/Resources/licenses"
# Inspect the original paths before dylibbundler rewrites them.
bash scripts/collect-macos-licenses.sh "$bundle/Contents/Resources/licenses" "$executable" "$server_executable"

cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>d4-plot</string>
  <key>CFBundleIdentifier</key><string>com.github.kojix2.d4-plot</string>
  <key>CFBundleName</key><string>D4 Plot</string>
  <key>CFBundleDisplayName</key><string>D4 Plot</string>
  <key>CFBundleIconFile</key><string>d4-plot.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string><string>ja</string><string>zh</string><string>es</string>
    <string>de</string><string>fr</string><string>ko</string><string>nl</string>
    <string>pt</string><string>pl</string><string>tr</string><string>ru</string>
    <string>hi</string><string>id</string><string>ur</string><string>vi</string>
    <string>he</string><string>ar</string><string>bn</string>
  </array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
</dict>
</plist>
EOF

# Copy Homebrew dylibs and rewrite their paths inside the bundle.
dylibbundler -ns -od -b -x "$executable" -x "$server_executable" \
  -d "$bundle/Contents/Frameworks" \
  -p '@executable_path/../Frameworks/'

codesign --force --deep --sign - "$bundle"

staging=$work/image
mkdir -p "$staging"
ditto "$bundle" "$staging/d4-plot.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "D4 Plot" -srcfolder "$staging" -format UDZO -ov "$work/package.dmg"
# Publish only a complete package; a failed build leaves the previous outputs.
rm -rf dist/d4-plot.app
mv "$bundle" dist/d4-plot.app
mv "$work/package.dmg" "$disk_image"
echo "Created $disk_image"
