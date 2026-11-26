// BorosKitRender: BKRaycastPass.h - the volume ray caster on the shared GPU interface (BKGPU.h): the same code runs
// on Metal (BKVolumeRenderer is its thin adapter) and on Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #4b, "RaycastPass").
//
// PORTING NOTES:
//   - Plain C++17 on BKGPU.h + BKShaderTypes.h / BKRenderCore.h (private headers of this module, next to it).
//     No Apple simd, no Objective-C, no Metal.
//   - Kernels (ShaderRef names): bk_raycast, bk_brick_ranges, bk_classify_bricks (shared bodies,
//     BKRaycastShaderBodies.h), and bk_raycast_texture (on-screen output; Metal only so far - the Vulkan on-screen
//     path, a storage image + copy to the swapchain, is planned in VULKAN-ENGINE-PROGRESS.md; hasTextureOutput()).
//   - Bindings (Metal index = slot; Vulkan binding = 16 + slot for textures, 40 for the sampler):
//       bk_raycast:         storage 0 params (inline bytes), 1 colours (RGBA8 packed per word), 2 values (float),
//                           3 brick "empty" list, 4 brick ranges; textures 0 scan, 1 colour table (RGBA32F 4096 x 1),
//                           3 object colours, 4 object ray distances (R32F), 5 fused scan, 6 fused table; sampler 0.
//       bk_raycast_texture: storage 0 params, 1 background (16 bytes), 2 empty list, 3 ranges; storage image 2 =
//                           target; textures as above.
//       bk_brick_ranges:    storage 0 ranges, 1 brick grid (uint4 inline); texture 0 scan.
//       bk_classify_bricks: storage 0 ranges, 1 alpha counts, 2 empty list, 3 params.
//     The sampler (linear, clamp, normalised) is bound everywhere: the Metal kernels use their own constexpr
//     samplers, the GLSL ones this one (texelFetch also needs a sampler object there).
//   - Missing optional inputs (objects, fused scan, brick lists) are replaced by the pass's 1-texel / 16-byte
//     placeholders; the kernel does not read them then (p.useGeometry / p.useBlend / p.skipEmptySpace = 0).
//   - Workgroups: 8 x 8 pixels (rays), 4 x 4 x 4 bricks - the Metal numbers.
//   - The caller owns policy and caches (which table / brick lists are current); WantsSkipping is the shared rule.
//
// Plain language: "draw the 3D picture of a scan on any graphics card".

#ifndef BK_RAYCAST_PASS_H
#define BK_RAYCAST_PASS_H

#ifdef __cplusplus

#include <memory>
#include <stdint.h>
#include "BKGPU.h"
#include "BKShaderTypes.h"

namespace boroskit {
namespace render {

// What the ray cast reads. Only volume and table are required.
struct RaycastInputs {
    gpu::Texture *volume = nullptr;            // R16Unorm (grey) or RGBA8Unorm (colour) 3D
    gpu::Texture *table = nullptr;             // RGBA32Float, BK_TRANSFER_FUNCTION_ENTRIES x 1
    gpu::Buffer *brickEmpty = nullptr;         // read when p.skipEmptySpace and composite
    gpu::Buffer *brickRange = nullptr;         // read when p.skipEmptySpace (MIP / MinIP)
    gpu::Texture *geometryColor = nullptr;     // embedded objects (p.useGeometry)
    gpu::Texture *geometryDistance = nullptr;  // R32Float
    gpu::Texture *blendVolume = nullptr;       // fused scan (p.useBlend)
    gpu::Texture *blendTable = nullptr;
};

class RaycastPass {
public:
    explicit RaycastPass(gpu::Device &device);
    ~RaycastPass();

    // What: pipelines, sampler, placeholders. Once. bk_raycast_texture is optional (see hasTextureOutput).
    gpu::Status prepare();
    bool hasTextureOutput() const;

    // The shared empty-space skipping rule: skipping is wanted unless switched off, in the average mode (it needs
    // every sample), or for colour scans / fusion (the bricks describe only a grey first scan).
    static bool WantsSkipping(bool skipsEmptySpace, const BKRenderParams &p);

    // What: a baked table (BK_TRANSFER_FUNCTION_ENTRIES RGBA floats, BKRenderTFBake) on the GPU (uploaded and waited
    // for) and, when alphaCount is given, its running count of non-see-through entries (BKRenderAlphaPrefixCount).
    gpu::Status makeTable(const float *rgba, std::unique_ptr<gpu::Texture> *table, std::unique_ptr<gpu::Buffer> *alphaCount);

    // What: the per-brick (lowest | highest << 16) list of a grey scan, built on the GPU and waited for.
    // grid = BKRenderBrickGrid of the scan size.
    std::unique_ptr<gpu::Buffer> makeBrickRanges(gpu::Texture &volume, const uint32_t grid[3], gpu::Status *status);

    // What: records the "which bricks are see-through" decision for p's table (composite mode) into `list`;
    // the new list is returned (one 32-bit word per brick). p.brickGrid must be set.
    std::unique_ptr<gpu::Buffer> encodeClassify(gpu::CommandList &list, const BKRenderParams &p, gpu::Buffer &brickRange,
                                                gpu::Buffer &alphaCount, gpu::Status *status);

    // What: records the ray cast of every output pixel into colorOut (p.width * p.height words; unused when
    // p.valuesOnly) and valueOut (floats).
    gpu::Status encodeRaycast(gpu::CommandList &list, const BKRenderParams &p, const RaycastInputs &in,
                              gpu::Buffer &colorOut, gpu::Buffer &valueOut);

    // What: the same straight into a storage image, laid over an opaque background colour (on-screen 3D view).
    gpu::Status encodeRaycastToTexture(gpu::CommandList &list, const BKRenderParams &p, const RaycastInputs &in,
                                       gpu::Texture &target, const float background[4]);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace render
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_RAYCAST_PASS_H
