// BorosKit GPU tests shared by EVERY backend (Vulkan plan phase 2: "both backends pass the SAME test code").
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine".
//
// PORTING NOTES:
//   - C++17 on BKGPU.h + BKMeshPass + the golden harness's plain-C half. Each test takes a gpu::Device and prints
//     its findings; the return value is the number of failures.
//   - Run by: the Vulkan programs (CMake / ctest: bk_vulkan_triangle_test, bk_golden_vulkan), the Mac XCTest suite
//     on a MetalDevice (Tests/BorosKitGoldenTests/BKGPUSharedTests.mm includes this code), and on this Mac the
//     live Metal-vs-Vulkan program bk_gpu_cross (CMake, Apple only).
//   - Shaders: the device must know bk_triangle_vertex / bk_triangle_fragment (triangle test) and BKMeshPass's
//     programs (Metal: BKMeshShaderSource library; Vulkan: embedded SPIR-V).

#ifndef BK_GPU_SHARED_TESTS_H
#define BK_GPU_SHARED_TESTS_H

#include "BKGPU.h"
#include <cstdint>
#include <string>
#include <vector>

namespace bkshared {

// What: one flat-coloured triangle; exact inside / outside, either colour within 0.75 pixel of an edge.
int TestTriangle(boroskit::gpu::Device &device);

// What: the golden mesh-render cases through BKMeshPass, compared with the Metal references (agreed tolerances; with
// `strict` zero tolerance). Writes <outDir>/<case>.<label>.rgba.pam / .distance.pfm when outDir is not null.
int TestGoldenMeshes(boroskit::gpu::Device &device, const char *referencesDir, const char *outDir, const char *label, bool strict);

// What: front / back faces: a counter-clockwise and a clockwise square (as seen on screen, y up) drawn with culling
// none / back / front; the result must match the plain-C rule BKMeshTriangleIsCulled (BKMeshDrawCore.h).
int TestWinding(boroskit::gpu::Device &device);

// What (2026-11-26, phase 3/4): GPU compute - an exclusive prefix sum of 100003 pseudo-random numbers in three
// dispatches (blocks, block sums, add), with workgroups of 256 and of 64 threads; must equal the CPU sum exactly.
// Shaders bk_test_scan_blocks / bk_test_scan_sums / bk_test_scan_add (Metal twins in BKGPUTestMetal.mm).
int TestComputeScan(boroskit::gpu::Device &device);

// What: a scene with every other kind BKMeshPass draws - solid and see-through lines, points, a textured quad
// (nearest + repeat, linear + clamp), a see-through mesh, a wireframe mesh, culling - rendered into RGBA8 + ray
// distance (96 x 80). `parts` picks what is drawn (2026-11-26: so each kind has its own recorded reference).
enum : uint32_t { kFeatureTextured = 1, kFeatureMeshes = 2, kFeatureLines = 4, kFeaturePoints = 8, kFeatureAll = 15 };
const uint32_t kFeatureWidth = 96, kFeatureHeight = 80;
bool RenderFeatureScene(boroskit::gpu::Device &device, std::vector<uint8_t> *rgba, std::vector<float> *distance,
                        uint32_t parts = kFeatureAll);

// What (2026-11-26, phase 3/4 step 2): RECORDED golden references for lines, points and textured meshes (until
// now only checked live, Metal vs Vulkan): feature_textured / feature_lines / feature_points / feature_scene
// (.rgba.pam + .distance.pfm in References/). record = write them (Metal only); strict = zero tolerance;
// otherwise the usual tolerances (u8 +-1 with 0.5 % outliers; distance 0.01 with 0.5 %).
struct FeatureGoldenCase { const char *name; uint32_t parts; };
const uint32_t kFeatureGoldenCaseCount = 4;
extern const FeatureGoldenCase kFeatureGoldenCases[kFeatureGoldenCaseCount];
int TestGoldenFeatures(boroskit::gpu::Device &device, const char *referencesDir, const char *outDir, const char *label,
                       bool strict, bool record);

// What (2026-11-26, phase 3/4 step 3): BKSurfacePass on this device - the three golden surface cases of the head
// phantom (bone 300 HU, skin -500 HU, bone at half resolution + smoothing with manual sampling) compared with the
// recorded Metal references (*.bkmesh; strict = zero tolerance, else 1e-4 voxel / 1e-3 normal) and, for the full-
// resolution cases, with the double-precision CPU reference BKSurfaceReferenceExtract. Prints exact differences.
int TestSurfacePass(boroskit::gpu::Device &device, const char *referencesDir, const char *label, bool strict);

// What (2026-11-26, Vulkan plan 7.1 #4c): the eight golden volume cases (composite ortho / perspective / clipped,
// MIP / MinIP / average slabs, thin oblique MPR, perspective MIP) through BKRaycastPass on this device, with the
// parameter block from BKRenderParamsFill (portable normalisation) and the same scan storage, tables, skipping and
// defaults as the golden producer. RenderRaycastCases returns the pictures (for live cross-backend comparisons);
// TestRaycastPass compares them with the recorded Metal references (golden tolerances) with hardware AND manual
// filtering, printing exact numbers, and writes them to outDir when given.
struct RaycastCaseOutput {
    std::string name;
    uint32_t width = 0, height = 0;
    int32_t mode = 0;
    std::vector<uint8_t> rgba;
    std::vector<float> values;
    bool valuesOnlyIdentical = false;   // the values-only (SlabPass) render gave exactly the same values
};
bool RenderRaycastCases(boroskit::gpu::Device &device, bool manualFiltering, std::vector<RaycastCaseOutput> *out);
// strict (2026-11-26, after the portable-normalise switch): zero tolerance for the hardware-filtered run (Metal).
int TestRaycastPass(boroskit::gpu::Device &device, const char *referencesDir, const char *outDir, const char *label,
                    bool strict = false);

// What (2026-11-26, Vulkan plan 7.1 #5): the five golden curved-reformat cases (both height limits) through
// ReformatPass on this device; compared with the recorded Metal references (strict = zero tolerance, else 1 HU /
// 0.5 %) and with the CPU reference BKReformatComputeRows (< 0.5 HU).
struct ReformatCaseOutput {
    std::string name;
    uint32_t width = 0, height = 0;
    std::vector<float> values, cpu;
};
// What (2026-11-26, Vulkan plan 7.1 #6): the 2D passes. RenderDisplayCases: DisplayPass pictures 96 x 80 -
// display_overlay_layer (linear grey + see-through label layer, = the BKGoldenTests reference) and display_lut_invert
// (nearest, colour table, inverted; live comparison only). RenderOverlayScene: OverlayPass draws the golden overlay
// scene (BKDisplayGoldenScene.h, incl. the segmentation label picture) over black; also vs the CPU rasteriser.
// Test2D: both vs the recorded Metal references (strict = zero tolerance).
struct RenderedPicture {
    std::string name;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> rgba;
};
bool RenderDisplayCases(boroskit::gpu::Device &device, std::vector<RenderedPicture> *out);
bool RenderOverlayScene(boroskit::gpu::Device &device, RenderedPicture *out, uint32_t *cpuDiffering, float *cpuWorst);
int Test2D(boroskit::gpu::Device &device, const char *referencesDir, const char *label, bool strict);

bool RenderReformatCases(boroskit::gpu::Device &device, std::vector<ReformatCaseOutput> *out);
int TestReformatPass(boroskit::gpu::Device &device, const char *referencesDir, const char *label, bool strict);

}  // namespace bkshared

#endif
