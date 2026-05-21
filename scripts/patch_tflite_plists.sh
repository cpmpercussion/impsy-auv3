#!/bin/zsh
# Patches missing CFBundleShortVersionString and MinimumOSVersion in the
# TFLite frameworks embedded in the app, and generates dSYMs for them so
# Xcode Cloud's upload-prep step doesn't choke. App Store Connect rejects
# builds without those plist keys (errors 90057, 90360, 90530), and
# kewlbear/TFLiteC's prebuilt binaries ship without dSYMs — locally
# Validate calls that a warning, but Xcode Cloud fails the upload step.
#
# Runs as a post-build script on both IMPSYHost-iOS and IMPSYExtension-iOS
# so each bundle's embedded copy is patched. After editing the Info.plist
# we must re-sign each framework — the existing signature was computed
# over the pre-patch plist. Xcode's final app code-sign (which happens
# after all build phases) then rebuilds the app's _CodeSignature against
# the new framework signatures. Idempotent.

set -euo pipefail

TFLITE_VERSION="2.14.0"
# Match the embedding app's iOS deployment target. App Store Connect rejects
# (ITMS-90208) when a framework's MinimumOSVersion is lower than the app's,
# even though the prebuilt TFLite binaries actually support iOS 12+.
MIN_OS="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

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

    # Generate a dSYM next to the framework binary so the archive's dSYMs
    # folder ends up with one matching the binary's LC_UUID. Prebuilt
    # binaries usually have no DWARF, but dsymutil still emits a stub
    # bundle with the correct UUID — enough for App Store upload.
    binary="$fw_dir/$fw_name"
    if [[ -f "$binary" && -n "${DWARF_DSYM_FOLDER_PATH:-}" ]]; then
        dsym_path="$DWARF_DSYM_FOLDER_PATH/${fw_name}.framework.dSYM"
        echo "patch_tflite_plists: generating dSYM at $dsym_path"
        dsymutil "$binary" -o "$dsym_path" || true
    fi

    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        echo "patch_tflite_plists: re-signing $fw_dir"
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$fw_dir"
    fi
done
