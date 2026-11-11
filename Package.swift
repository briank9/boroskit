// swift-tools-version:5.9
// BorosKit: the shared imaging engine for Boros on macOS and iOS/iPadOS.
// BorosKitCore is plain Objective-C/C (no AppKit, UIKit or OpenGL) so the same
// code can run in the Mac app and a future iPad app.
// BorosKitRender is the GPU layer on Apple's Metal (the replacement for VTK + OpenGL),
// also shared by macOS and iOS.
import PackageDescription

let package = Package(
    name: "BorosKit",
    platforms: [.macOS(.v12), .iOS(.v16)],
    products: [
        .library(name: "BorosKitCore", targets: ["BorosKitCore"]),
        .library(name: "BorosKitRender", targets: ["BorosKitRender"]),
        // BorosKitDisplay (2D image display: Metal image + CoreGraphics overlays)
        .library(name: "BorosKitDisplay", targets: ["BorosKitDisplay"]),
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
        .target(
            name: "BorosKitRender",
            dependencies: ["BorosKitCore"],
            path: "Sources/BorosKitRender",
            publicHeadersPath: "include",
            cSettings: [
                // New code: automatic reference counting (unlike the Horos-derived core).
                .unsafeFlags(["-fobjc-arc"]),
            ],
            cxxSettings: [
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "BorosKitRenderTests",
            dependencies: ["BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitRenderTests",
            // Real Horos/Boros 3D presets and colour tables, used to check the preset loader.
            resources: [.copy("Fixtures")],
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .testTarget(
            name: "BorosKitCoreTests",
            dependencies: ["BorosKitCore"],
            path: "Tests/BorosKitCoreTests"
        ),
        // --- BorosKitDisplay: 2D image display for Mac and iPad (replaces OpenGL DCMView drawing) ---
        .target(
            name: "BorosKitDisplay",
            // Core: N3 geometry, N3BezierPath for curve overlays.
            // Render: BKVolumeScene/BKVolumeRenderer for the interactive 3D view (BKVolumeView),
            // so all on-screen views live in one UI module and Render stays UI-free.
            dependencies: ["BorosKitCore", "BorosKitRender"],
            path: "Sources/BorosKitDisplay",
            publicHeadersPath: "include",
            cSettings: [
                // New code: automatic reference counting.
                .unsafeFlags(["-fobjc-arc"]),
            ],
            cxxSettings: [
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "BorosKitDisplayTests",
            dependencies: ["BorosKitDisplay", "BorosKitCore", "BorosKitRender"],
            path: "Tests/BorosKitDisplayTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // --- end BorosKitDisplay ---
    ]
)
