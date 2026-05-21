#!/bin/zsh
# Patches missing CFBundleShortVersionString and MinimumOSVersion in the
# TFLite frameworks embedded in the app. App Store Connect rejects builds
# without these keys (errors 90057 and 90360/90530). The kewlbear/TFLiteC
# binaries wrap Google's official TFLite without the required metadata.
#
# Runs as a post-build script on IMPSYHost-iOS so it can edit the already-
# embedded frameworks. After editing the Info.plist we must re-sign each
# framework — the framework's existing signature was computed over the
# pre-patch plist. Xcode's final app code-sign (which happens after all
# build phases) then rebuilds the app's _CodeSignature against the new
# framework signatures. Idempotent.

set -euo pipefail

TFLITE_VERSION="2.14.0"
MIN_OS="12.0"

FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$WRAPPER_NAME/Frameworks"
if [[ ! -d "$FRAMEWORKS_DIR" ]]; then
    echo "patch_tflite_plists: no frameworks dir at $FRAMEWORKS_DIR; skipping"
    exit 0
fi

for fw_name in TensorFlowLiteC TensorFlowLiteCCoreML TensorFlowLiteCMetal; do
    fw_dir="$FRAMEWORKS_DIR/${fw_name}.framework"
    plist="$fw_dir/Info.plist"
    [[ -f "$plist" ]] || { echo "patch_tflite_plists: $plist missing; skipping"; continue; }

    echo "patch_tflite_plists: patching $plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $TFLITE_VERSION" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TFLITE_VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MIN_OS" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN_OS" "$plist"

    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        echo "patch_tflite_plists: re-signing $fw_dir"
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$fw_dir"
    fi
done
