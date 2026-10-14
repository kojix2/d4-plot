#!/usr/bin/env bash
set -euo pipefail

# After replacing the master PNG, refresh the tracked Windows and Linux assets.
magick assets/d4-plot.png -resize 256x256 -strip assets/d4-plot-256.png
magick assets/d4-plot.png -define icon:auto-resize=256,128,64,48,32,16 assets/d4-plot.ico
