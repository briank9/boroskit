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
// distance (96 x 80). Used to compare two backends with each other (no recorded reference yet).
bool RenderFeatureScene(boroskit::gpu::Device &device, std::vector<uint8_t> *rgba, std::vector<float> *distance);

}  // namespace bkshared

#endif
