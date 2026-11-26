// BorosKitSurface: BKSurfacePass.h - surface extraction (marching cubes on the GPU) written once on the shared GPU
// interface (BKGPU.h), so the same code runs on Metal (BKSurfaceExtractor is its thin adapter) and on Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 step 3, "SurfacePass").
//
// PORTING NOTES:
//   - Plain C++17 on BKGPU.h + the plain-C core BKSurfaceCore.h. No Apple simd, no Objective-C, no Metal.
//   - Kernels (ShaderRef names): bk_surface_sample, bk_surface_blur, bk_surface_classify, bk_surface_emit.
//     Metal: BKSurfaceShaderSource.mm (MSL, compiled by the adapter, handed over with BKGPUMetalAddLibrary).
//     Vulkan: Sources/BorosKitGPUVulkan/Shaders/bk_surface_*.comp (GLSL twins, line by line the same maths).
//   - Bindings (both backends): storage slot 0 = BKSurfaceParams (336 bytes, std430, inline bytes), 1 field,
//     2 packed (blur: 1 = source, 2 = destination), 3 row vertices / row vertex starts, 4 row triangles / starts,
//     5 marching-cubes table, 6 positions, 7 normals, 8 indices; sampled texture 0 = the scan (R16Unorm, 3D);
//     sampler 0 = linear + clamp (bound for every kernel: Vulkan's texelFetch needs a sampler object too).
//   - Workgroup sizes are fixed per pipeline (BKGPU.h ComputeDesc): rows use the largest power of two <= 256 the
//     GPU accepts, sample / blur use (32, 4, 2) shrunk until accepted. Results do not depend on either size.
//   - Vulkan needs SAMPLED_IMAGE_FILTER_LINEAR for R16_UNORM 3D images only for the hardware sampling mode; the
//     manual mode (BK_SURFACE_SAMPLING_MANUAL) reads exact texels and runs everywhere.
//   - Same flow as the Metal code it replaced: one command list for sampling + blur; per threshold classify ->
//     CPU row prefix sum (on the mapped row tables) -> exact-size outputs -> emit -> hand the mesh to the caller.
//
// Plain language: "build a bone / skin surface from a scan on any graphics card". The caller turns the result
// into its own mesh object (BKMesh on the Mac).

#ifndef BK_SURFACE_PASS_H
#define BK_SURFACE_PASS_H

#ifdef __cplusplus

#include <memory>
#include <stdint.h>
#include "BKGPU.h"
#include "BKSurfaceCore.h"

namespace boroskit {
namespace surface {

// One finished surface, valid only during the MeshSink call (it points into GPU-readable memory).
// positions / normals: 4 floats per vertex (x, y, z, unused) - the memory layout of simd_float3.
struct MeshView {
    const float *positions = nullptr;
    const float *normals = nullptr;
    const uint32_t *indices = nullptr;   // 3 per triangle
    uint64_t vertexCount = 0, triangleCount = 0;   // 0 / 0 = nothing crosses this threshold (not an error)
};

// What: receives each surface in threshold order. Return BKSurfaceStatusOK to go on, anything else to stop
// (that status is returned by extract).
typedef BKSurfaceStatus (*MeshSink)(void *context, uint32_t thresholdIndex, const MeshView &mesh);

struct Stats {
    uint32_t gridWidth = 0, gridHeight = 0, gridDepth = 0;
    double samplingMilliseconds = 0;     // sample + blur
    double extractionMilliseconds = 0;   // classify + scan + emit (without the time spent in the MeshSink)
    double sinkMilliseconds = 0;         // time spent in the MeshSink (the caller's mesh building)
    uint64_t vertexCount = 0, triangleCount = 0;   // all thresholds together
    uint64_t peakTemporaryBytes = 0;
    const char *detail = nullptr;        // extra words for an error, e.g. "(The threshold is not a number.)"
};

class SurfacePass {
public:
    explicit SurfacePass(gpu::Device &device);
    ~SurfacePass();

    // What: makes the four pipelines, the sampler and the marching-cubes table. Once, before extract.
    BKSurfaceStatus prepare();

    // What: one surface per threshold (thresholdSteps = the threshold in stored 16-bit steps, see
    // BKSurfaceThresholdToSteps). `request` maxBufferBytes / memoryBudgetBytes of 0 are filled from the device
    // limits. `volume` is the scan as an R16Unorm 3D texture. Thread-safe: no state is kept between calls.
    BKSurfaceStatus extract(gpu::Texture &volume, const BKSurfacePlanRequest &request, const float *thresholdSteps,
                            uint32_t thresholdCount, MeshSink sink, void *context, Stats *stats);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace surface
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_SURFACE_PASS_H
