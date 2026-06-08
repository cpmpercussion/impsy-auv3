#!/usr/bin/env bash
#
# capture-screenshots.sh — generate App Store + website screenshots for IMPSY.
#
# Drives ScreenshotCaptureTests (TestsUI/Shared) on the iPhone 6.9", iPad 13"
# and macOS hosts, in light and dark, and pulls the screenshots out of the
# .xcresult. iOS shots are full-screen with a mocked 9:41 status bar; macOS
# shots are window captures, also composited onto a 16:10 branded canvas for
# the Mac App Store (which requires 16:10).
#
# Output: $OUT (default /tmp/impsy-screenshots)
#   iphone/   1320x2868  impsy-{light,dark}-{dashboard,settings,mapping}.png
#   ipad/     2064x2752  …
#   macos/    window captures
#   macos-appstore/  2880x1800 (16:10) composites
#
# Usage: ./scripts/capture-screenshots.sh [all|iphone|ipad|macos]   (default all)
#
# Must run from an interactive GUI session (XCUITest needs the automation
# handshake); the runner may time out enabling automation — just re-run.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="IMPSY-AUv3.xcodeproj"
OUT="${OUT:-/tmp/impsy-screenshots}"
IPHONE_TYPE="${IPHONE_TYPE:-iPhone 17 Pro Max}"      # 6.9" -> 1320x2868
IPAD_TYPE="${IPAD_TYPE:-iPad Pro 13-inch (M5)}"      # 13"  -> 2064x2752
WHAT="${1:-all}"
mkdir -p "$OUT"

udid_for() { xcrun simctl list devices available | grep -F "$1 (" | head -1 | grep -oE '[0-9A-F-]{36}'; }

export_atts() { # <xcresult> <dest-dir>
  local res="$1" dst="$2" tmp; tmp="$(mktemp -d)"
  xcrun xcresulttool export attachments --path "$res" --output-path "$tmp" >/dev/null
  python3 - "$tmp" "$dst" <<'PY'
import json, re, shutil, os, sys
src, dst = sys.argv[1], sys.argv[2]; os.makedirs(dst, exist_ok=True)
for e in json.load(open(f"{src}/manifest.json")):
    for a in e.get("attachments", []):
        c = re.sub(r"_\d+_[0-9A-Fa-f-]+\.png$", ".png", a["suggestedHumanReadableName"])
        if c.startswith("impsy-"):
            shutil.copy(f"{src}/{a['exportedFileName']}", f"{dst}/{c}")
PY
  rm -rf "$tmp"
}

capture_ios() { # <device-type> <out-subdir> <scheme>
  local type="$1" sub="$2" scheme="$3" udid res
  udid="$(udid_for "$type")"; [ -n "$udid" ] || { echo "No simulator for '$type'"; exit 1; }
  echo "==> $type ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  rm -rf "${OUT:?}/$sub"
  for ap in light dark; do
    xcrun simctl ui "$udid" appearance "$ap"
    xcrun simctl status_bar "$udid" override --time "9:41" \
      --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    res="$OUT/$sub-$ap.xcresult"; rm -rf "$res"
    echo "    capturing $ap …"
    TEST_RUNNER_IMPSY_CAPTURE=1 TEST_RUNNER_IMPSY_SHOT_APPEARANCE="$ap" \
      xcodebuild test -project "$PROJ" -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:IMPSYUITests-iOS/ScreenshotCaptureTests/testCaptureScreens \
        -resultBundlePath "$res" >/dev/null 2>&1
    export_atts "$res" "$OUT/$sub"
  done
  xcrun simctl status_bar "$udid" clear || true
}

# macOS XCUITest's automation handshake is unreliable from a scripted shell, so
# we drive the macOS host directly: launch the built app with the model/config/
# appearance/screen injected via env (HostTestHooks + the IMPSY_TEST_* hooks),
# then grab the window with screencapture (needs Screen Recording permission for
# the terminal). The window id comes from a tiny CGWindowList Swift helper.
capture_macos() {
  echo "==> macOS"
  rm -rf "${OUT:?}/macos" "$OUT/macos-appstore"; mkdir -p "$OUT/macos" "$OUT/macos-appstore"

  xcodebuild build -project "$PROJ" -scheme IMPSYHost-macOS -destination "platform=macOS" >/dev/null 2>&1
  local app bin
  app="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/IMPSY-AUv3-*/Build/Products/Debug/IMPSY.app | head -1)"
  bin="$app/Contents/MacOS/IMPSY"

  local winid_swift; winid_swift="$(mktemp /tmp/impsy-winid-XXXX.swift)"
  cat > "$winid_swift" <<'SWIFT'
import CoreGraphics
import Foundation
let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in infos where (w[kCGWindowOwnerName as String] as? String) == "IMPSY"
    && (w[kCGWindowLayer as String] as? Int) == 0 {
  if let n = w[kCGWindowNumber as String] as? Int { print(n); break }
}
SWIFT

  local model config; model="$(base64 -i Tests/Fixtures/musicMDRNN-dim9-layers2-units64-mixtures5-scale10.tflite)"
  config="$(base64 -i Tests/Fixtures/AiC-charles-u6midipro.toml)"

  for ap in light dark; do
    for screen in dashboard settings mapping; do
      pkill -f "IMPSY.app/Contents/MacOS/IMPSY" 2>/dev/null || true; sleep 1
      IMPSY_TEST_MODEL_B64="$model" IMPSY_TEST_CONFIG_B64="$config" \
        IMPSY_TEST_APPEARANCE="$ap" IMPSY_TEST_SCREEN="$screen" "$bin" >/dev/null 2>&1 &
      sleep 7
      local wid; wid="$(swift "$winid_swift" 2>/dev/null)"
      [ -n "$wid" ] || { echo "    !! no window id for $ap/$screen"; continue; }
      echo "    capturing $ap/$screen (window $wid)"
      screencapture -o -l"$wid" "$OUT/macos/impsy-$ap-$screen.png"
    done
  done
  pkill -f "IMPSY.app/Contents/MacOS/IMPSY" 2>/dev/null || true

  # 3-up 16:10 mockup (Dashboard · Settings · Mapping) per appearance, for the
  # Mac App Store (which requires 16:10). Hairline border + branded canvas so
  # the windows separate cleanly from the background.
  for ap in light dark; do
    local bg bc
    if [ "$ap" = dark ]; then bg='#2b5230'; bc='rgba(255,255,255,0.16)'
    else                      bg='#fbf8ee'; bc='rgba(0,0,0,0.10)'; fi
    magick -size 2880x1800 "xc:$bg" \
      \( "$OUT/macos/impsy-$ap-dashboard.png" -resize x1400 -bordercolor "$bc" -border 2 \) -gravity northwest -geometry +56+200 -composite \
      \( "$OUT/macos/impsy-$ap-settings.png"  -resize x1400 -bordercolor "$bc" -border 2 \) -gravity northwest -geometry +1005+200 -composite \
      \( "$OUT/macos/impsy-$ap-mapping.png"   -resize x1400 -bordercolor "$bc" -border 2 \) -gravity northwest -geometry +1954+200 -composite \
      "$OUT/macos-appstore/impsy-macos-trio-$ap.png"
  done
}

case "$WHAT" in
  iphone) capture_ios "$IPHONE_TYPE" iphone IMPSYHost-iOS ;;
  ipad)   capture_ios "$IPAD_TYPE"   ipad   IMPSYHost-iOS ;;
  macos)  capture_macos ;;
  all)    capture_ios "$IPHONE_TYPE" iphone IMPSYHost-iOS
          capture_ios "$IPAD_TYPE"   ipad   IMPSYHost-iOS
          capture_macos ;;
  *) echo "usage: $0 [all|iphone|ipad|macos]"; exit 1 ;;
esac

echo "Done. Screenshots in $OUT"
ls -1 "$OUT"/*/*.png 2>/dev/null | sed "s|$OUT/||"
