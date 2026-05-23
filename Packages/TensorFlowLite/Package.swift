// swift-tools-version:5.9
//
// Local Swift package that vends TensorFlow Lite to the IMPSY targets,
// bundling iOS slices (kewlbear, v2.14.0) and a macOS arm64 slice
// (tphakala, v2.17.1) into a single TensorFlowLiteC.xcframework. The
// xcframework is built by ../../scripts/build_tflite_xcframework.sh and
// is intentionally not committed to the repo.
//
// The Swift wrapper sources under Sources/TensorFlowLite/ are vendored
// from kewlbear/TensorFlowLiteSwift, which in turn re-exports
// google/tensorflow's tensorflow/lite/swift/Sources/. License: Apache 2.0
// (see LICENSE-APACHE-2.0).

import PackageDescription

let package = Package(
    name: "TensorFlowLite",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TensorFlowLite", targets: ["TensorFlowLite"]),
    ],
    targets: [
        // libc++ link is required by the TFLite C binary. SPM forbids
        // linkerSettings on a binary target, so we add it via a tiny
        // sibling Swift target and pull it in transitively.
        .target(
            name: "TensorFlowLiteCLink",
            path: "Sources/TensorFlowLiteCLink",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(
            name: "TensorFlowLiteC",
            path: "Frameworks/TensorFlowLiteC.xcframework"
        ),
        .target(
            name: "TensorFlowLite",
            dependencies: ["TensorFlowLiteC", "TensorFlowLiteCLink"],
            path: "Sources/TensorFlowLite"
        ),
    ]
)
