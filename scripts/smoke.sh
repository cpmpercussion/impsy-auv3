#!/bin/bash
# Combined smoke / regression runner for the IMPSY host apps.
#
# Usage:
#   scripts/smoke.sh                # runs all targets (ios, macos, tests)
#   scripts/smoke.sh ios            # iOS simulator host smoke
#   scripts/smoke.sh macos          # macOS host smoke
#   scripts/smoke.sh tests [ios|macos|all]
#                                   # XCUITest suites (default: all)
#
# Env knobs:
#   SIM_NAME      iOS simulator name (default: "iPhone 17")
#   ART_DIR       Where to drop screenshots and logs (default: /tmp/impsy-smoke)

set -euo pipefail

PROJECT="IMPSY-AUv3.xcodeproj"
SIM_NAME="${SIM_NAME:-iPhone 17}"
IOS_BUNDLE_ID="au.charlesmartin.impsy"
IOS_SCHEME="IMPSYHost-iOS"
MAC_SCHEME="IMPSYHost-macOS"
DD="/tmp/impsy-dd"
ART_DIR="${ART_DIR:-/tmp/impsy-smoke}"
mkdir -p "$ART_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
fail() { echo "==> FAIL: $*" >&2; exit 1; }

resolve_sim() {
  xcrun simctl list devices available \
    | grep "$SIM_NAME (" \
    | head -1 \
    | grep -oE '[0-9A-F-]{36}'
}

# ── iOS smoke ────────────────────────────────────────────────────────────────

smoke_ios() {
  local sim_id
  sim_id=$(resolve_sim)
  [ -z "$sim_id" ] && fail "No '$SIM_NAME' simulator found"
  xcrun simctl boot "$sim_id" 2>/dev/null || true
  xcrun simctl bootstatus "$sim_id" -b >/dev/null

  log "Building $IOS_SCHEME for $SIM_NAME ($sim_id)"
  xcodebuild build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -destination "platform=iOS Simulator,id=$sim_id" \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1

  local app="$DD/Build/Products/Debug-iphonesimulator/IMPSYHost-iOS.app"
  log "Installing and launching iOS host"
  xcrun simctl terminate "$sim_id" "$IOS_BUNDLE_ID" 2>/dev/null || true
  xcrun simctl uninstall "$sim_id" "$IOS_BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$sim_id" "$app"
  xcrun simctl launch "$sim_id" "$IOS_BUNDLE_ID" >/dev/null
  sleep 6

  log "[IMPSY] log output:"
  local logs
  logs=$(xcrun simctl spawn "$sim_id" log show \
    --predicate 'processImagePath CONTAINS "IMPSYHost"' \
    --last 30s --style compact 2>/dev/null | grep "\[IMPSY\]" || true)
  echo "$logs"

  xcrun simctl io "$sim_id" screenshot "$ART_DIR/ios-host.png" >/dev/null 2>&1 || true
  log "Screenshot: $ART_DIR/ios-host.png"

  local rc=0
  echo "$logs" | grep -q "Loaded bundled model" \
    && log "PASS: bundled model inspected" \
    || { echo "==> FAIL: bundled model did not load"; rc=1; }
  echo "$logs" | grep -q "RNN ready" \
    && log "PASS: TFLite RNN initialised" \
    || { echo "==> FAIL: TFLite RNN did not initialise"; rc=1; }
  return $rc
}

# ── macOS smoke ──────────────────────────────────────────────────────────────

smoke_macos() {
  log "Building $MAC_SCHEME (Debug)"
  xcodebuild build -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -destination "platform=macOS,arch=arm64" \
    -configuration Debug \
    -derivedDataPath "$DD" 2>&1 | tail -1

  # Scheme is IMPSYHost-macOS but the product builds as IMPSY.app (PRODUCT_NAME).
  local app="$DD/Build/Products/Debug/IMPSY.app"
  [ -d "$app" ] || fail "Built app not found at $app"

  log "Launching $app"
  # Kill any prior instance so launch is deterministic and the log window is fresh.
  pkill -f "IMPSY.app/Contents/MacOS/" 2>/dev/null || true
  # Record start time so log show only returns lines since launch.
  local since
  since=$(date "+%Y-%m-%d %H:%M:%S")
  open -n "$app"
  sleep 6

  log "[IMPSY] log output:"
  local logs
  logs=$(log show --predicate 'processImagePath CONTAINS "IMPSY.app"' \
    --start "$since" --style compact 2>/dev/null | grep "\[IMPSY\]" || true)
  echo "$logs"

  # Capture a screenshot of the host window (if screencapture is available).
  screencapture -x "$ART_DIR/macos-host.png" 2>/dev/null || true

  pkill -f "IMPSY.app/Contents/MacOS/" 2>/dev/null || true

  local rc=0
  echo "$logs" | grep -q "Loaded bundled model" \
    && log "PASS: bundled model inspected" \
    || { echo "==> FAIL: bundled model did not load"; rc=1; }
  echo "$logs" | grep -q "RNN ready" \
    && log "PASS: TFLite RNN initialised" \
    || { echo "==> FAIL: TFLite RNN did not initialise"; rc=1; }
  if echo "$logs" | grep -q "MIDI Bridge.*failed"; then
    echo "==> FAIL: CoreMIDI bridge reports failed"; rc=1
  else
    log "PASS: CoreMIDI bridge did not log a failure"
  fi
  return $rc
}

# ── XCUITest suites ──────────────────────────────────────────────────────────

run_tests() {
  local which="${1:-all}"
  local rc=0

  if [ "$which" = "ios" ] || [ "$which" = "all" ]; then
    local sim_id
    sim_id=$(resolve_sim)
    [ -z "$sim_id" ] && fail "No '$SIM_NAME' simulator found"
    log "Running IMPSYUITests-iOS on $SIM_NAME"
    xcodebuild test -project "$PROJECT" -scheme "$IOS_SCHEME" \
      -destination "platform=iOS Simulator,id=$sim_id" \
      -only-testing:IMPSYUITests-iOS \
      -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
      | tail -40 || rc=1
  fi
  if [ "$which" = "macos" ] || [ "$which" = "all" ]; then
    log "Running IMPSYUITests-macOS"
    xcodebuild test -project "$PROJECT" -scheme "$MAC_SCHEME" \
      -destination "platform=macOS,arch=arm64" \
      -only-testing:IMPSYUITests-macOS \
      -derivedDataPath "$DD" \
      | tail -40 || rc=1
  fi
  return $rc
}

# ── dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-all}"
shift || true

case "$cmd" in
  ios)    smoke_ios ;;
  macos)  smoke_macos ;;
  tests)  run_tests "${1:-all}" ;;
  all)
    rc=0
    smoke_ios   || rc=$?
    smoke_macos || rc=$?
    run_tests all || rc=$?
    exit $rc
    ;;
  -h|--help|help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    echo "Try: $0 [ios|macos|tests|all]" >&2
    exit 2
    ;;
esac
