#!/bin/bash
# Smoke test for the IMPSY host app on the iOS Simulator.
# Builds, installs, launches, captures [IMPSY] logs and a screenshot,
# and asserts the bundled model loaded successfully.
set -euo pipefail

SIM_NAME="${SIM_NAME:-iPhone 17}"
BUNDLE_ID="au.com.charlesmartin.impsy.host"
DD="/tmp/impsy-dd"
PROJECT="IMPSY-AUv3.xcodeproj"
SCHEME="IMPSYHost-iOS"
ART_DIR="/tmp/impsy-smoke"
mkdir -p "$ART_DIR"

# Resolve a booted simulator, booting one if needed.
SIM_ID=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 | grep -oE '[0-9A-F-]{36}')
[ -z "$SIM_ID" ] && { echo "No '$SIM_NAME' simulator found"; exit 1; }
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null

echo "==> Building $SCHEME for $SIM_NAME ($SIM_ID)"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1

APP="$DD/Build/Products/Debug-iphonesimulator/IMPSYHost-iOS.app"
echo "==> Installing and launching"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID"
sleep 6

echo "==> [IMPSY] log output:"
LOGS=$(xcrun simctl spawn "$SIM_ID" log show \
  --predicate 'processImagePath CONTAINS "IMPSYHost"' \
  --last 30s --style compact 2>/dev/null | grep "\[IMPSY\]" || true)
echo "$LOGS"

xcrun simctl io "$SIM_ID" screenshot "$ART_DIR/host.png" >/dev/null 2>&1
echo "==> Screenshot: $ART_DIR/host.png"

FAIL=0
echo "$LOGS" | grep -q "Loaded bundled model" \
  && echo "==> PASS: model inspected and bundled" \
  || { echo "==> FAIL: bundled model did not load"; FAIL=1; }
echo "$LOGS" | grep -q "RNN ready" \
  && echo "==> PASS: TFLite RNN initialised" \
  || { echo "==> FAIL: TFLite RNN did not initialise"; FAIL=1; }
exit $FAIL
