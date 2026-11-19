#!/usr/bin/env bash
# Makes the Play feature graphic (1024 × 500) from the app icon, with ImageMagick 7.
#   android/PlayStore/screenshots/make-feature-graphic.sh [font]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
font=${1:-/Library/Fonts/Roboto-Bold.ttf}   # any TTF; Roboto is Android's own face
magick -size 1024x500 xc:'#C2D4CD' \
  \( "$here/icon-512.png" -resize 360x360 \) -gravity west -geometry +70+0 -composite \
  -font "$font" -fill '#17353A' -gravity west \
  -pointsize 84 -annotate +480-60 'Rupert' \
  -pointsize 34 -fill '#0E6F72' -annotate +484+30 'Shop back office' \
  -pointsize 26 -fill '#17353A' -annotate +484+80 'Sales, stock and team, together' \
  -strip "$here/feature-graphic.png"
