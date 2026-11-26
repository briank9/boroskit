// BorosKitRender: BKReformatPass.h - the curved reformat (curved MPR / panorex pictures) on the shared GPU interface
// (BKGPU.h): the same code runs on Metal (BKCurvedReformat is its thin adapter) and on Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #5, "ReformatPass").
//
// PORTING NOTES:
//   - Plain C++17 on BKGPU.h + BKCurvedReformatCore.h (BKReformatParams / BKReformatFrame, both std430, pinned).
//   - Kernel bk_curved_reformat (shared body BKReformatShaderBodies.h): storage 0 params (inline bytes), 1 column
//     frames (3 float4 each), 2 values (float); texture 0 the scan (R16Unorm 3D, exact reads); sampler 0 (only so
//     GLSL's texelFetch has a sampler object; no filtering). Workgroup 8 x 8 (the Metal numbers).
//   - Both height limits are in the params (Mac band: bandEnabled + the frames' w height functions; Boros Mobile
//     clip band: clipEnabled). The export row range of the band is CPU-only: BKReformatBandRows (core).
//   - CPU reference: BKReformatComputeRows (core), deterministic, rows independent.
//
// Plain language: "draw a curved MPR / panorex picture on any graphics card".

#ifndef BK_REFORMAT_PASS_H
#define BK_REFORMAT_PASS_H

#ifdef __cplusplus

#include <memory>
#include "BKGPU.h"
#include "BKCurvedReformatCore.h"

namespace boroskit {
namespace render {

class ReformatPass {
public:
    explicit ReformatPass(gpu::Device &device);
    ~ReformatPass();

    gpu::Status prepare();

    // What: the column frames (params.width of them) in GPU-readable memory.
    std::unique_ptr<gpu::Buffer> makeFrames(const BKReformatFrame *frames, uint32_t count, gpu::Status *status);

    // What: records the picture (params.width * params.height floats into `values`). params' volume fields
    // (size, valueScale / valueOffset) must describe `volume`.
    gpu::Status encode(gpu::CommandList &list, const BKReformatParams &params, gpu::Buffer &frames, gpu::Texture &volume,
                       gpu::Buffer &values);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace render
}  // namespace boroskit

#endif  // __cplusplus
#endif  // BK_REFORMAT_PASS_H
