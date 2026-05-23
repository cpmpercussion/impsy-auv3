#!/bin/zsh
# Builds Packages/TensorFlowLite/Frameworks/TensorFlowLiteC.xcframework by
# combining kewlbear's iOS TFLite slices (v2.14.0, baked into release
# 0.0.20250619) with tphakala's prebuilt macOS arm64 TFLite C dylib
# (v2.17.1). The resulting xcframework feeds the local Packages/TensorFlowLite
# Swift package, which is what the four app/extension targets link against.
#
# Why we mix versions: kewlbear ships no macOS slice; tphakala ships no
# darwin_amd64 build for v2.17.1 *and* the v2.14.0 "darwin_arm64" asset is
# actually an x86_64 binary (mislabeled). v2.17.1 arm64 is the only correctly
# built recent Mac arm64 prebuilt we can use. The C ABI is stable between
# 2.14 and 2.17 so the iOS Swift wrapper works against either.
#
# Apple Silicon Macs only. Intel Mac support would need a source build of
# darwin_amd64 (issue #14 follow-up).
#
# Idempotent: re-running replaces the output framework cleanly.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR}/.."
PKG_DIR="${REPO_ROOT}/Packages/TensorFlowLite"
OUT_DIR="${PKG_DIR}/Frameworks"
OUT_XCF="${OUT_DIR}/TensorFlowLiteC.xcframework"

IOS_PKG_TAG="0.0.20250619"
MAC_TFLITE_VERSION="2.17.1"
MAC_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

WORK="$(mktemp -d -t impsy-tflite-build)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Workspace: $WORK"

# ── 1. iOS xcframework (kewlbear) ────────────────────────────────────────────
IOS_URL="https://github.com/kewlbear/TensorFlowLiteC/releases/download/${IOS_PKG_TAG}/TensorFlowLiteC.xcframework.zip"
echo "==> Downloading iOS xcframework from kewlbear (${IOS_PKG_TAG})"
curl -fsSL -o "$WORK/ios.zip" "$IOS_URL"
unzip -q "$WORK/ios.zip" -d "$WORK/ios"

IOS_FW=$(find "$WORK/ios" -name TensorFlowLiteC.framework -path '*ios-arm64/*' ! -path '*simulator*' -maxdepth 4 | head -1)
IOS_SIM_FW=$(find "$WORK/ios" -name TensorFlowLiteC.framework -path '*simulator*' -maxdepth 4 | head -1)
[[ -d "$IOS_FW" ]]     || { echo "FAILED: ios-arm64 framework not found"; exit 1 }
[[ -d "$IOS_SIM_FW" ]] || { echo "FAILED: ios simulator framework not found"; exit 1 }
echo "    device-slice:    $IOS_FW"
echo "    simulator-slice: $IOS_SIM_FW"

# ── 2. macOS arm64 dylib (tphakala) ──────────────────────────────────────────
MAC_URL="https://github.com/tphakala/tflite_c/releases/download/v${MAC_TFLITE_VERSION}/tflite_c_v${MAC_TFLITE_VERSION}_darwin_arm64.tar.gz"
echo "==> Downloading macOS arm64 dylib from tphakala (v${MAC_TFLITE_VERSION})"
curl -fsSL -o "$WORK/mac.tar.gz" "$MAC_URL"
mkdir "$WORK/mac"
tar -xzf "$WORK/mac.tar.gz" -C "$WORK/mac"
MAC_DYLIB=$(find "$WORK/mac" -maxdepth 2 -name 'libtensorflowlite_c*.dylib' | head -1)
[[ -n "$MAC_DYLIB" ]] || { echo "FAILED: macOS dylib not found in tarball"; exit 1 }

# Sanity-check architecture (tphakala has shipped mislabeled assets before).
MAC_ARCH=$(lipo -archs "$MAC_DYLIB")
[[ "$MAC_ARCH" == "arm64" ]] || { echo "FAILED: expected arm64, got '$MAC_ARCH' from $MAC_DYLIB"; exit 1 }
echo "    dylib: $MAC_DYLIB ($MAC_ARCH)"

# ── 3. Wrap macOS dylib in a versioned framework bundle ──────────────────────
# macOS frameworks use the canonical Versions/A/ layout (not the shallow
# layout iOS uses). The xcodebuild validator rejects shallow macOS
# frameworks with "expected Versions/Current/Resources/Info.plist".
MAC_FW="$WORK/macos-arm64/TensorFlowLiteC.framework"
MAC_VER="$MAC_FW/Versions/A"
mkdir -p "$MAC_VER/Resources" "$MAC_VER/Modules"

# vtool lowers LC_BUILD_VERSION's minos so the dylib loads on macOS
# ${MAC_DEPLOYMENT_TARGET}+ (tphakala builds with whatever SDK is on the
# runner; v2.17.1 currently reports minos 15.2 which is too high for us).
echo "==> Repacking dylib at deployment target macOS ${MAC_DEPLOYMENT_TARGET}"
vtool -set-build-version macos "$MAC_DEPLOYMENT_TARGET" "$MAC_DEPLOYMENT_TARGET" \
  -output "$MAC_VER/TensorFlowLiteC" "$MAC_DYLIB"
install_name_tool -id "@rpath/TensorFlowLiteC.framework/Versions/A/TensorFlowLiteC" \
  "$MAC_VER/TensorFlowLiteC"

# Copy the iOS slice's umbrella headers + module.modulemap. The TFLite C
# API is stable across 2.14↔2.17 (function signatures unchanged), so the
# v2.14.0 iOS headers work fine against the v2.17.1 macOS binary for the
# symbols the Swift wrapper uses (TfLiteModelCreate, TfLiteInterpreter*,
# TfLiteTensor*, TfLiteVersion, etc.).
cp -R "$IOS_FW/Headers" "$MAC_VER/Headers"
cp "$IOS_FW/Modules/module.modulemap" "$MAC_VER/Modules/module.modulemap"

# Info.plist mirroring the iOS slice's keys plus the App-Store-required
# CFBundleShortVersionString / LSMinimumSystemVersion. Avoids the patch
# dance that patch_tflite_plists.sh does on iOS — we control this build.
cat > "$MAC_VER/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TensorFlowLiteC</string>
  <key>CFBundleIdentifier</key><string>au.charlesmartin.impsy.TensorFlowLiteC</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>TensorFlowLiteC</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${MAC_TFLITE_VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>${MAC_DEPLOYMENT_TARGET}</string>
  <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
EOF
plutil -convert binary1 "$MAC_VER/Resources/Info.plist"

# Versions/Current → A, plus the top-level symlinks Apple's validator expects.
ln -s "A"                   "$MAC_FW/Versions/Current"
ln -s "Versions/Current/TensorFlowLiteC" "$MAC_FW/TensorFlowLiteC"
ln -s "Versions/Current/Headers"         "$MAC_FW/Headers"
ln -s "Versions/Current/Modules"         "$MAC_FW/Modules"
ln -s "Versions/Current/Resources"       "$MAC_FW/Resources"

# ── 4. Assemble xcframework ──────────────────────────────────────────────────
echo "==> Creating combined xcframework"
mkdir -p "$OUT_DIR"
rm -rf "$OUT_XCF"
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$IOS_SIM_FW" \
  -framework "$MAC_FW" \
  -output "$OUT_XCF"

echo "==> Done: $OUT_XCF"
ls "$OUT_XCF"
