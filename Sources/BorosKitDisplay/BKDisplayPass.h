// BorosKitDisplay: BKDisplayPass.h - the 2D image display (one full-screen triangle; window / level, colour table,
// nearest or bilinear by hand) on the shared GPU interface (BKGPU.h): the same code runs on Metal
// (BKImageLayerRenderer is its thin adapter) and on Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #6, "DisplayPass").
//
// PORTING NOTES:
//   - Plain C++17 on BKGPU.h + BKDisplayShaderTypes.h (BKDisplayParams, 80 bytes, std430, pinned).
//   - Shaders bk_display_vertex / bk_display_fragment (shared bodies BKDisplayShaderBodies.h). Bindings: fragment
//     storage 0 = params (inline bytes), texture 0 = the image (R32Float grey or RGBA8 colour, exact reads),
//     texture 1 = the 256 x 1 RGBA8 colour table; sampler 0 (GLSL texelFetch needs one; never filters).
//   - Draws INTO a pass the caller began (or a caller's Metal encoder via BKGPUMetalCommandListForEncoder).
//     blended = a see-through layer over what is there (ColorTarget::straightOverKeepAlpha: colour straight-alpha
//     over, destination alpha kept) - BKImageLayerRenderer's overlay layer.
//   - Textures belong to the caller (the Mac adapter keeps its CPU-written Metal textures; others upload them).
//
// Plain language: "show a slice on screen with brightness / contrast, on any graphics card".

#ifndef BK_DISPLAY_PASS_H
#define BK_DISPLAY_PASS_H

#ifdef __cplusplus

#include <memory>
#include "BKGPU.h"
#include "BKDisplayShaderTypes.h"

namespace boroskit {
namespace display {

class DisplayPass {
public:
    explicit DisplayPass(gpu::Device &device);
    ~DisplayPass();
    gpu::Status prepare();
    // What: one full-screen draw of `image` into the current pass (colour format `target`).
    gpu::Status encode(gpu::CommandList &list, const BKDisplayParams &params, gpu::Texture &image, gpu::Texture &lut,
                       gpu::Format target, bool blended);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace display
}  // namespace boroskit

#endif
#endif
