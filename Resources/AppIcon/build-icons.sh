#!/usr/bin/env bash
# Regenerate the app icon PNGs in IMPSYHost/Assets.xcassets/AppIcon.appiconset
# from icon.svg. Run after editing icon.svg.
#
# Rendering uses qlmanage (QuickLook → WebKit) for full SVG fidelity, since no
# rsvg-convert / Inkscape / cairosvg is assumed present. ImageMagick handles
# the rest (alpha flatten, rounded mask, downscaling).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SVG="$HERE/icon.svg"
OUT="$HERE/../../IMPSYHost/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

# 1. Render the full-bleed master at 1024.
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1
MASTER="$TMP/icon.svg.png"
[ -f "$MASTER" ] || { echo "error: SVG render failed" >&2; exit 1; }

# 2. iOS — single 1024 full-bleed, opaque (App Store icons must have no alpha).
magick "$MASTER" -background '#437742' -alpha remove -alpha off \
  -resize 1024x1024 "$OUT/icon-ios-1024.png"

# 3. macOS — rounded square with ~10% padding on a transparent canvas.
INSET=100; SQ=824; R=184
magick "$MASTER" -resize ${SQ}x${SQ} "$TMP/content.png"
magick -size ${SQ}x${SQ} xc:none -fill white \
  -draw "roundrectangle 0,0,$((SQ-1)),$((SQ-1)),$R,$R" "$TMP/mask.png"
magick "$TMP/content.png" "$TMP/mask.png" \
  -alpha off -compose CopyOpacity -composite "$TMP/rounded.png"
magick -size 1024x1024 xc:none \
  "$TMP/rounded.png" -geometry +${INSET}+${INSET} -compose over -composite \
  "$TMP/mac-1024.png"
for s in 16 32 64 128 256 512 1024; do
  magick "$TMP/mac-1024.png" -filter Lanczos -resize ${s}x${s} "$OUT/icon-mac-${s}.png"
done

echo "Icons written to ${OUT#"$HERE/../../"}"
