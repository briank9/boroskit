// swift-tools-version:5.9
// BorosKit: the shared imaging engine for Boros on macOS and iOS/iPadOS.
// BorosKitCore is plain Objective-C/C (no AppKit, UIKit or OpenGL) so the same
// code can run in the Mac app and a future iPad app.
import PackageDescription

let package = Package(
    name: "BorosKit",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "BorosKitCore", targets: ["BorosKitCore"]),
    ],
    targets: [
        .target(
            name: "BorosKitCore",
            path: "Sources/BorosKitCore",
            publicHeadersPath: "include",
            cSettings: [
                // The code comes from Horos, which uses manual retain/release.
                // Keep it that way so behaviour is unchanged.
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "BorosKitCoreTests",
            dependencies: ["BorosKitCore"],
            path: "Tests/BorosKitCoreTests"
        ),
    ]
)
