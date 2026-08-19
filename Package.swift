// swift-tools-version: 6.0
import PackageDescription

// A camera that knows how to capture and nothing about where the bytes go.
//
// Extracted from the vault app once it became clear the camera would keep growing —
// modes, live filters, a scanner, editing. In a single module nothing stops the camera
// reaching back into app types, and `tools/check-arch.sh` is a grep: it cannot see
// "the camera just used the app's font". A package makes the compiler the enforcement.
let package = Package(
    name: "KVCameraKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "KVCameraKit", targets: ["KVCameraKit"])
    ],
    targets: [
        .target(
            name: "KVCameraKit",
            path: "Sources/KVCameraKit"
        ),
        .testTarget(
            name: "KVCameraKitTests",
            dependencies: ["KVCameraKit"],
            path: "Tests/KVCameraKitTests"
        )
    ]
)
