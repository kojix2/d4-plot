#!/usr/bin/env bash
set -euo pipefail
tag=$1
version=${tag#v}

work=build/package-deb
package=$work/debian/d4-plot
install -d -m 755 "$package/DEBIAN" "$package/usr/bin" \
  "$package/usr/share/applications" "$package/usr/share/doc/d4-plot" \
  "$package/usr/share/icons/hicolor/256x256/apps"
install -m 755 bin/d4-plot "$package/usr/bin/d4-plot"
install -m 644 assets/d4-plot-256.png "$package/usr/share/icons/hicolor/256x256/apps/d4-plot.png"
install -m 644 LICENSE "$package/usr/share/doc/d4-plot/copyright"
install -m 644 README.md "$package/usr/share/doc/d4-plot/README.md"
bash scripts/collect-licenses.sh "$package/usr/share/doc/d4-plot/licenses"

cat > "$package/usr/share/applications/d4-plot.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=D4 Plot
Comment=View D4 genomic signal
Exec=d4-plot %f
Icon=d4-plot
Terminal=false
Categories=Science;Education;
EOF
chmod 644 "$package/usr/share/applications/d4-plot.desktop"

cat > "$work/debian/control" <<'EOF'
Source: d4-plot

Package: d4-plot
Architecture: amd64
Description: GUI viewer for D4 genomic signal
EOF

shlibs=$(cd "$work" && dpkg-shlibdeps -O -e debian/d4-plot/usr/bin/d4-plot)
depends=${shlibs#shlibs:Depends=}
cat > "$package/DEBIAN/control" <<EOF
Package: d4-plot
Version: $version
Section: science
Priority: optional
Architecture: amd64
Maintainer: kojix2 <2xijok@gmail.com>
Depends: $depends
Description: GUI viewer for D4 genomic signal
 D4 Plot displays genomic signal and annotations from D4 files.
EOF
chmod 644 "$package/DEBIAN/control"

mkdir -p dist
archive="dist/d4-plot_${version}_amd64.deb"
dpkg-deb --build --root-owner-group "$package" "$archive"
echo "Created $archive"
