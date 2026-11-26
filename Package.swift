// swift-tools-version:5.9
// BorosKit: the shared imaging engine for Boros on macOS and iOS/iPadOS.
// BorosKitCore is plain Objective-C/C (no AppKit, UIKit or OpenGL) so the same
// code can run in the Mac app and a future iPad app.
// BorosKitRender is the GPU layer on Apple's Metal (the replacement for VTK + OpenGL),
// also shared by macOS and iOS.
import PackageDescription
import Foundation   // 2026-11-26: FileManager / ProcessInfo (finding the Vulkan SDK headers)

// CPU floating-point rule for ALL BorosKit library code (2026-11-25, Vulkan engine kickoff, user decision D3):
// -ffp-contract=off = never fuse a*b+c into one rounding step (FMA). Apple clang fuses by default, GCC /
// MSVC behave differently, so without this the cores (mesh smoothing / decimation, transfer-function bake,
// camera maths ...) could differ in the last bit between the Mac build and a Windows / Linux (CMake) build
// and flip decisions. CMakeLists.txt uses the same flag. No fast-math anywhere.
let bkFloatingPoint = "-ffp-contract=off"

// 2026-11-26 (Boros 6 MoltenVK test switch): the Vulkan SDK's include folder, when installed (user decision D2: Vulkan
// headers only from the installed SDK, nothing vendored). Newest ~/VulkanSDK/<version>/macOS/include, else
// $VULKAN_SDK/include; /usr/local/include (the SDK's system install) is searched by clang anyway. Without any of
// them BorosKitGPUVulkan builds as a stub (BKVulkanAvailable.h) and the app simply has no Vulkan test engine.
let bkVulkanIncludeFlags: [String] = {
    var candidates: [String] = []
    if let sdk = ProcessInfo.processInfo.environment["VULKAN_SDK"] { candidates.append(sdk + "/include") }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VulkanSDK").path
    let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    candidates += versions.map { root + "/" + $0 + "/macOS/include" }
    for dir in candidates where FileManager.default.fileExists(atPath: dir + "/vulkan/vulkan.h") {
        return ["-I" + dir]
    }
    return []
}()

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
        // BorosKitGPU (2026-11-26, Vulkan plan phase 2): the backend-neutral GPU interface (BKGPU.h) + its Metal device.
        .library(name: "BorosKitGPU", targets: ["BorosKitGPU"]),
        // BorosKitGPUVulkan (2026-11-26): the Vulkan engine (MoltenVK on a Mac) - used only as Boros 6's TEST engine.
        .library(name: "BorosKitGPUVulkan", targets: ["BorosKitGPUVulkan"]),
        // BorosKitDICOM (2026-11-24, iOS app): BorosKit's own licence-free DICOM reader
        .library(name: "BorosKitDICOM", targets: ["BorosKitDICOM"]),
        // BorosKitVec (2026-11-24): exported so app code (Swift) can use the BKVec types of the plain-C cores
        .library(name: "BorosKitVec", targets: ["BorosKitVec"]),
        // BorosKitSegmentation (2026-11-26, agent "segmentation"): segmentations as label maps (+ class surfaces)
        .library(name: "BorosKitSegmentation", targets: ["BorosKitSegmentation"]),
    ],
    targets: [
        // BorosKitVec (2026-11-14): BorosKit's own neutral vector types for the plain-C cores
        // (pure C99, header-only). No Apple simd, no Objective-C, no LGPL N3 types: the portable
        // base layer shared with the future Vulkan engine (VULKAN-PORT-PLAN.md sections 14 / R1).
        .target(
            name: "BorosKitVec",
            path: "Sources/BorosKitVec",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags([bkFloatingPoint])]
        ),
        .target(
            name: "BorosKitCore",
            // Vec (2026-11-24, vtk-data): the plain-C maths cores here (BKRigidFitCore ...) use BKVec3d.
            dependencies: ["BorosKitVec"],
            path: "Sources/BorosKitCore",
            publicHeadersPath: "include",
            cSettings: [
                // The code comes from Horos, which uses manual retain/release.
                // Keep it that way so behaviour is unchanged.
                .unsafeFlags(["-fno-objc-arc", bkFloatingPoint]),
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
            // GPU (2026-11-26, Vulkan plan 7.1 #4b): BKRaycastPass runs on the shared GPU interface (BKVolumeRenderer
            // is its Metal adapter). BorosKitGPU therefore no longer depends on BorosKitRender (no cycle).
            dependencies: ["BorosKitCore", "BorosKitVec", "BorosKitGPU"],
            path: "Sources/BorosKitRender",
            publicHeadersPath: "include",
            cSettings: [
                // New code: automatic reference counting (unlike the Horos-derived core).
                .unsafeFlags(["-fobjc-arc", bkFloatingPoint]),
            ],
            cxxSettings: [
                .unsafeFlags(["-fobjc-arc", bkFloatingPoint]),
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
            // Vec (2026-11-14): BKTextLayoutCore (plain-C label placement) uses BKVec2f.
            // GPU (2026-11-26, Vulkan plan 7.1 #6): DisplayPass / OverlayPass run on the shared GPU interface.
            dependencies: ["BorosKitCore", "BorosKitRender", "BorosKitVec", "BorosKitGPU"],
            path: "Sources/BorosKitDisplay",
            publicHeadersPath: "include",
            cSettings: [
                // New code: automatic reference counting.
                .unsafeFlags(["-fobjc-arc", bkFloatingPoint]),
            ],
            cxxSettings: [
                .unsafeFlags(["-fobjc-arc", bkFloatingPoint]),
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
            // Recorded values of the old (Horos) ROI code, read from the source folder by the ROI core
            // tests (2026-11-16, overlay-engine plan step 1) - not compiled, not bundled.
            exclude: ["References"],
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
            // Vec (2026-11-25, vulkan-engine M1): BKParallel.h (the one parallel-for helper) now lives there.
            dependencies: ["BorosKitCore", "BorosKitVec"],
            path: "Sources/BorosKitMesh",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        // --- BorosKitGPU (2026-11-26, Vulkan plan phase 2): BKGPU.h (C++17, backend-neutral GPU interface) and
        // MetalDevice (BKGPUMetal.mm, Objective-C++). The Vulkan device is NOT here (CMake only), so building Boros 6
        // never needs the Vulkan SDK. Render: BKMetalDevice (preferred GPU, shader compile options).
        .target(
            name: "BorosKitGPU",
            dependencies: ["BorosKitVec"],   // 2026-11-26: no longer BorosKitRender (it now depends on this target)
            path: "Sources/BorosKitGPU",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation"),
                             .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("QuartzCore")]   // test-engine marker / timing (2026-11-26)
        ),
        // BorosKitGPUVulkan (2026-11-26, Boros 6 MoltenVK test switch): VulkanDevice + its embedded SPIR-V
        // (Generated/BKVulkanShaderTable.cpp, generated from OUR GLSL by CMake - see docs/tools/update-vulkan-shaders.sh)
        // + the test-engine registration. The Vulkan loader is opened at run time from the user's SDK; never linked.
        // Render: BKGPUChoiceCore (GPU choice rules).
        .target(
            name: "BorosKitGPUVulkan",
            dependencies: ["BorosKitGPU", "BorosKitRender", "BorosKitVec"],
            path: "Sources/BorosKitGPUVulkan",
            exclude: ["Shaders"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint] + bkVulkanIncludeFlags)],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint] + bkVulkanIncludeFlags)],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "BorosKitMeshRender",
            // Render: BKVolumeCamera / BKRenderResult, so meshes use the volume's camera.
            // GPU (2026-11-26): BKMeshPass draws through the shared GPU interface (BKMeshRenderer is its Metal glue).
            dependencies: ["BorosKitMesh", "BorosKitRender", "BorosKitCore", "BorosKitVec", "BorosKitGPU"],
            path: "Sources/BorosKitMeshRender",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation"),
                             .linkedFramework("CoreText"), .linkedFramework("CoreGraphics")]   // system-font cube letters (2026-11-14)
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
            // Vec (2026-11-25, vulkan-engine M1): BKOnce.h (portable run-once for the case tables).
            // GPU (2026-11-26, Vulkan plan 7.1 step 3): BKSurfacePass runs on the shared GPU interface.
            dependencies: ["BorosKitCore", "BorosKitRender", "BorosKitMesh", "BorosKitVec", "BorosKitGPU"],
            path: "Sources/BorosKitSurface",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "BorosKitSurfaceTests",
            dependencies: ["BorosKitSurface", "BorosKitMesh", "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitSurfaceTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        // --- end BorosKitSurface ---
        // --- BorosKitSegmentation (2026-11-26, agent "segmentation"): a segmentation as its own data type - a label
        // map on the scan's voxel grid + class table, the .boroseg file, measurements, slice / plane sampling, overlay
        // pictures (plain C API, C++ core BKSegmentationCore.cpp, also built by CMake) and the class surface glue
        // (BKLabelSurface.mm: mask -> BKSurfaceExtractor -> BKMesh in patient mm).
        .target(
            name: "BorosKitSegmentation",
            dependencies: ["BorosKitSurface", "BorosKitRender", "BorosKitMesh", "BorosKitCore", "BorosKitVec"],
            path: "Sources/BorosKitSegmentation",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", bkFloatingPoint])],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "BorosKitSegmentationTests",
            dependencies: ["BorosKitSegmentation", "BorosKitSurface", "BorosKitMesh", "BorosKitRender", "BorosKitCore"],
            path: "Tests/BorosKitSegmentationTests",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-ffp-contract=off"])]
        ),
        // --- end BorosKitSegmentation ---
        // --- BorosKitDICOM (2026-11-24, Boros Mobile): an original DICOM reader (no DCMTK / GDCM), plain-C cores
        // (parser, lossless JPEG, RLE, slice sorting) + thin Apple glue (file reading, ImageIO for JPEG / JPEG 2000).
        .target(
            name: "BorosKitDICOM",
            dependencies: ["BorosKitVec"],
            path: "Sources/BorosKitDICOM",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("ImageIO"),
                             .linkedFramework("CoreGraphics"), .linkedLibrary("compression")]
        ),
        .testTarget(
            name: "BorosKitDICOMTests",
            dependencies: ["BorosKitDICOM", "BorosKitVec"],
            path: "Tests/BorosKitDICOMTests",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("ImageIO"), .linkedFramework("CoreGraphics")]
        ),
        // --- end BorosKitDICOM ---
        // --- Golden-output harness: fixed synthetic phantoms run through every GPU operation,
        // compared with recorded reference files (images, meshes, numbers, export bytes).
        // Today Metal records the references; a future Vulkan backend is checked against the
        // same files. Record: BK_GOLDEN_RECORD=1 swift test -c release --filter BKGoldenTests
        // The reference files are read from the source folder (not bundled as resources).
        .testTarget(
            name: "BorosKitGoldenTests",
            // GPU (2026-11-26, phase 2): BKGPUSharedTests.mm runs the backend-shared GPU tests on a MetalDevice.
            dependencies: ["BorosKitSurface", "BorosKitMeshRender", "BorosKitMesh", "BorosKitDisplay",
                           "BorosKitRender", "BorosKitCore", "BorosKitGPU", "BorosKitGPUVulkan"],
            path: "Tests/BorosKitGoldenTests",
            exclude: ["References"],
            // -ffp-contract=off: the phantom generator must give bit-identical scans on every
            // platform (no fused multiply-add rounding), see BKGoldenCore.h.
            cSettings: [.unsafeFlags(["-fobjc-arc", "-ffp-contract=off"])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", "-ffp-contract=off"])]
        ),
    ]
    // C++17 for the plain C++ cores (std::to_chars in BKSceneExportCore).
    , cxxLanguageStandard: .gnucxx17
)
