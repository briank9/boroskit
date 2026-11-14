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
        // BorosKitMesh (surface meshes + STL/PLY/OBJ files) and BorosKitMeshRender (Metal mesh drawing)
        .library(name: "BorosKitMesh", targets: ["BorosKitMesh"]),
        .library(name: "BorosKitMeshRender", targets: ["BorosKitMeshRender"]),
        // BorosKitSurface (bone / skin surfaces from a scan, built on the GPU)
        .library(name: "BorosKitSurface", targets: ["BorosKitSurface"]),
    ],
    targets: [
        // BorosKitVec (2026-11-14): BorosKit's own neutral vector types for the plain-C cores
        // (pure C99, header-only). No Apple simd, no Objective-C, no LGPL N3 types: the portable
        // base layer shared with the future Vulkan engine (VULKAN-PORT-PLAN.md sections 14 / R1).
        .target(
            name: "BorosKitVec",
            path: "Sources/BorosKitVec",
            publicHeadersPath: "include"
        ),
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
            dependencies: ["BorosKitCore", "BorosKitVec"],
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
        // --- Accuracy check: a synthetic "phantom" scan with known markers, rendered through
        // every image path (MPR/slab, 3D, CPR, 2D display) to prove orientation, left/right
        // and distances are exactly right. See ACCURACY.md.
        .testTarget(
            name: "BorosKitAccuracyTests",
            dependencies: ["BorosKitDisplay", "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitAccuracyTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // --- BorosKitMesh: surface meshes (bone surfaces, intraoral scans, implants) ---
        .target(
            name: "BorosKitMesh",
            // Core: N3 geometry (patient mm transforms). No GPU code here.
            dependencies: ["BorosKitCore"],
            path: "Sources/BorosKitMesh",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "BorosKitMeshRender",
            // Render: BKVolumeCamera / BKRenderResult, so meshes use the volume's camera.
            dependencies: ["BorosKitMesh", "BorosKitRender", "BorosKitCore", "BorosKitVec"],
            path: "Sources/BorosKitMeshRender",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "BorosKitMeshTests",
            dependencies: ["BorosKitMesh", "BorosKitMeshRender", "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitMeshTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // --- end BorosKitMesh ---
        // --- BorosKitSurface: GPU isosurface extraction (replaces VTK contour/decimate/smooth) ---
        .target(
            name: "BorosKitSurface",
            // Render: BKVolumeTexture (the scan on the GPU). Mesh: BKMesh (the result).
            // The plain-C core (BKSurfaceCore) uses none of them, so a Vulkan backend can reuse it.
            dependencies: ["BorosKitCore", "BorosKitRender", "BorosKitMesh"],
            path: "Sources/BorosKitSurface",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "BorosKitSurfaceTests",
            dependencies: ["BorosKitSurface", "BorosKitMesh", "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitSurfaceTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // --- end BorosKitSurface ---
        // --- Golden-output harness: fixed synthetic phantoms run through every GPU operation,
        // compared with recorded reference files (images, meshes, numbers, export bytes).
        // Today Metal records the references; a future Vulkan backend is checked against the
        // same files. Record: BK_GOLDEN_RECORD=1 swift test -c release --filter BKGoldenTests
        // The reference files are read from the source folder (not bundled as resources).
        .testTarget(
            name: "BorosKitGoldenTests",
            dependencies: ["BorosKitSurface", "BorosKitMeshRender", "BorosKitMesh", "BorosKitDisplay",
                           "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitGoldenTests",
            exclude: ["References"],
            // -ffp-contract=off: the phantom generator must give bit-identical scans on every
            // platform (no fused multiply-add rounding), see BKGoldenCore.h.
            cSettings: [.unsafeFlags(["-fobjc-arc", "-ffp-contract=off"])]
        ),
    ]
    // C++17 for the plain C++ cores (std::to_chars in BKSceneExportCore).
    , cxxLanguageStandard: .gnucxx17
)
