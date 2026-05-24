#!/bin/zsh
# Build a signed, notarised, stapled macOS release of IMPSY for direct
# distribution (outside the Mac App Store).
#
# Pipeline:
#   xcodegen        → regenerate project.pbxproj from project.yml
#   xcodebuild      → archive IMPSYHost-macOS (Release, arm64)
#   xcodebuild      → exportArchive with method=developer-id (signs host + .appex
#                     with the Developer ID Application cert, applies Hardened
#                     Runtime, embeds entitlements)
#   codesign        → verify the .app and the embedded .appex
#   ditto + zip     → submit .app to Apple's notary service via notarytool
#   stapler         → staple the notarisation ticket onto the .app
#   hdiutil         → wrap the stapled .app in a UDZO .dmg
#   notarytool      → notarise + staple the .dmg (so Gatekeeper validates
#                     the disk image itself when users mount it)
#
# Prereqs (run once):
#   1. Developer ID Application cert installed in login keychain.
#   2. App-specific password generated at appleid.apple.com.
#   3. Store credentials in keychain:
#        xcrun notarytool store-credentials IMPSY_NOTARY \
#          --apple-id chuckempire@gmail.com \
#          --team-id EDH387FRHA \
#          --password <app-specific-password>
#   4. Packages/TensorFlowLite/Frameworks/TensorFlowLiteC.xcframework present
#      (run scripts/build_tflite_xcframework.sh if missing).
#
# Usage:
#   scripts/release-macos.sh                 # full pipeline → DMG
#   scripts/release-macos.sh --skip-notarize # archive/export/verify only (dry run)
#   scripts/release-macos.sh --no-dmg        # stop after stapling the .app
#
# Env knobs:
#   NOTARY_PROFILE   notarytool keychain profile name (default: IMPSY_NOTARY)
#   BUILD_DIR        artifact root (default: build/release-macos)
#   SCHEME           Xcode scheme (default: IMPSYHost-macOS)

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR}/.."
cd "$REPO_ROOT"

PROJECT="IMPSY-AUv3.xcodeproj"
SCHEME="${SCHEME:-IMPSYHost-macOS}"
CONFIG="Release"
BUILD_DIR="${BUILD_DIR:-build/release-macos}"
ARCHIVE_PATH="${BUILD_DIR}/IMPSY.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${SCRIPT_DIR}/ExportOptions-macOS.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-IMPSY_NOTARY}"
TFLITE_XCF="Packages/TensorFlowLite/Frameworks/TensorFlowLiteC.xcframework"

SKIP_NOTARIZE=0
MAKE_DMG=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --no-dmg)        MAKE_DMG=0 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log()  { print -P "%F{cyan}==>%f $*"; }
ok()   { print -P "%F{green}==>%f $*"; }
fail() { print -P "%F{red}==> FAIL:%f $*" >&2; exit 1; }

if command -v xcbeautify >/dev/null; then
  XCFORMAT=(xcbeautify --quiet)
else
  XCFORMAT=(tail -5)
fi

# ── preflight ────────────────────────────────────────────────────────────────

command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
[[ -d "$TFLITE_XCF" ]] || fail "Missing $TFLITE_XCF — run scripts/build_tflite_xcframework.sh"

if (( ! SKIP_NOTARIZE )); then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "notarytool profile '$NOTARY_PROFILE' missing. Run:
    xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id chuckempire@gmail.com \\
      --team-id EDH387FRHA \\
      --password <app-specific-password>"
  fi
fi

# Refuse to ship if a Developer ID Application cert isn't installed.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  fail "No 'Developer ID Application' certificate in login keychain"
fi

# ── regenerate + clean ───────────────────────────────────────────────────────

log "xcodegen generate"
xcodegen generate >/dev/null

log "Clean $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Read version from project.yml so we can name artefacts deterministically.
MARKETING_VERSION=$(awk '/MARKETING_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
BUILD_NUMBER=$(awk '/CURRENT_PROJECT_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
log "Version: $MARKETING_VERSION ($BUILD_NUMBER)"

# ── archive ──────────────────────────────────────────────────────────────────

log "Archiving $SCHEME ($CONFIG, arm64)"
# `generic/platform=macOS` rejects an `arch=` qualifier — arm64-only is enforced
# by `ARCHS[sdk=macosx*]=arm64` in project.yml (TFLite ships no x86_64 mac slice).
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  | "${XCFORMAT[@]}"

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive not produced at $ARCHIVE_PATH"

# ── export with Developer ID ─────────────────────────────────────────────────

log "Exporting Developer ID signed .app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  | "${XCFORMAT[@]}"

APP_PATH=$(find "$EXPORT_DIR" -maxdepth 2 -name "*.app" | head -1)
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "Exported .app not found under $EXPORT_DIR"
APPEX_PATH=$(find "$APP_PATH/Contents/PlugIns" -maxdepth 1 -name "*.appex" | head -1)
[[ -n "$APPEX_PATH" && -d "$APPEX_PATH" ]] || fail "AUv3 .appex not found inside $APP_PATH"

log "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$APPEX_PATH"
codesign -dvv "$APP_PATH"   2>&1 | grep -E "Authority|TeamIdentifier|Identifier|flags" | sed 's/^/    /'
codesign -dvv "$APPEX_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier|flags" | sed 's/^/    /'

# Hardened Runtime is mandatory for Developer ID notarisation. Catch a
# misconfigured project before burning a notary submission. (Note: capture the
# whole signing dump up front — piping into `grep -q` triggers SIGPIPE in
# codesign once grep exits early, which `set -o pipefail` then surfaces.)
for bin in "$APP_PATH" "$APPEX_PATH"; do
  sig=$(codesign -dvv "$bin" 2>&1)
  [[ "$sig" == *"(runtime)"* ]] || \
    fail "Hardened Runtime not enabled on $bin — set ENABLE_HARDENED_RUNTIME=YES in project.yml"
done

ok "Built and signed: $APP_PATH"

if (( SKIP_NOTARIZE )); then
  ok "Stopped before notarization (--skip-notarize)"
  exit 0
fi

# ── notarize the .app ────────────────────────────────────────────────────────

APP_ZIP="${BUILD_DIR}/IMPSY-${MARKETING_VERSION}.zip"
log "Zipping .app for notarytool → $APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

log "Submitting .app to notary service (this can take a few minutes)"
# `notarytool --wait` exits 0 even when status=Invalid, so we have to parse.
SUBMIT_LOG="${BUILD_DIR}/notary-submit.log"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait | tee "$SUBMIT_LOG"

if ! grep -qE "status: Accepted" "$SUBMIT_LOG"; then
  SUBMISSION_ID=$(awk '/^  id:/ {print $2; exit}' "$SUBMIT_LOG")
  print -P "%F{red}==> Notarisation failed.%f Apple's log:" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  fail "Notarisation rejected — fix the issues above and rerun."
fi

log "Stapling notarisation ticket onto .app"
xcrun stapler staple "$APP_PATH"
spctl -a -vv -t exec "$APP_PATH" 2>&1 | sed 's/^/    /'

# Refresh the zip so the artefact users download contains the stapled ticket.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
ok "Notarised + stapled .app: $APP_PATH"
ok "Distributable zip:        $APP_ZIP"

if (( ! MAKE_DMG )); then
  exit 0
fi

# ── DMG ──────────────────────────────────────────────────────────────────────

DMG_PATH="${BUILD_DIR}/IMPSY-${MARKETING_VERSION}.dmg"
log "Building DMG → $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "IMPSY" \
  -srcfolder "$APP_PATH" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

# Sign the disk image with Developer ID + secure timestamp. The .app inside is
# already signed; signing the DMG too gives Gatekeeper something to evaluate on
# the image itself (not just the extracted .app) and is now expected practice.
log "Signing DMG"
codesign --sign "Developer ID Application: Charles Martin (EDH387FRHA)" \
  --timestamp "$DMG_PATH"

log "Notarising DMG"
DMG_SUBMIT_LOG="${BUILD_DIR}/notary-submit-dmg.log"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait | tee "$DMG_SUBMIT_LOG"

if ! grep -qE "status: Accepted" "$DMG_SUBMIT_LOG"; then
  SUBMISSION_ID=$(awk '/^  id:/ {print $2; exit}' "$DMG_SUBMIT_LOG")
  print -P "%F{red}==> DMG notarisation failed.%f Apple's log:" >&2
  [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fail "DMG notarisation rejected."
fi

log "Stapling DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH" | sed 's/^/    /'

ok "Distributable DMG: $DMG_PATH"
