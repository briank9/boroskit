// BorosKitDisplay: BKOverlayPass.h - the 2D overlay engine's GPU half (a BKOverlayCore draw list: triangles with
// colours, images and masks, clips, opaque runs) on the shared GPU interface (BKGPU.h): the same code runs on Metal
// (BKOverlayRenderer is its thin adapter) and on Vulkan. The CPU rasteriser BKOverlayRasterize is the reference.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan step 7.1 #6, "OverlayPass").
//
// PORTING NOTES:
//   - Plain C++17 on BKGPU.h + BKOverlayCore.h. Shaders bk_overlay_vertex / bk_overlay_fragment (shared bodies
//     BKOverlayShaderBodies.h). Bindings: storage 0 = the vertices (BKOverlayVertex, 32 bytes; vertex stage),
//     storage 1 = BKOverlayParams (inline bytes, both stages), texture 0 + sampler 0 (fragment).
//   - Pipeline per target format: premultiplied "over" (one, one-minus-source-alpha). Per command: scissor (its
//     clip, or the whole view), image (or the pass's 1 x 1 white), nearest / linear clamp sampler, triangle range.
//     The scissor is left at the whole view afterwards.
//   - Draws INTO a pass the caller began (or a caller's Metal encoder via BKGPUMetalCommandListForEncoder).
//   - Images / vertices: the caller hands them over as GPU objects (the Mac adapter writes Metal shared memory
//     directly as before); makeVertices / makeImages are the generic way (images uploaded in a command list that
//     must be submitted before the pass).
//   - Text: glyphs reach the list as BKOverlayImageAlpha8 masks (on the Mac drawn by the existing CoreText glyph
//     source). A Windows / Linux glyph source is decision D4 (still open; see VULKAN-ENGINE-PROGRESS.md) - the pass
//     itself needs nothing else.
//   - Segmentation label maps (BorosKitSegmentation, Boros 6 BorosSegmentationOverlay.m) draw as RGBA8 image
//     commands (nearest) - no special path.

#ifndef BK_OVERLAY_PASS_H
#define BK_OVERLAY_PASS_H

#ifdef __cplusplus

#include <memory>
#include <vector>
#include "BKGPU.h"
#include "BKOverlayCore.h"

namespace boroskit {
namespace display {

class OverlayPass {
public:
    explicit OverlayPass(gpu::Device &device);
    ~OverlayPass();
    gpu::Status prepare();   // samplers, the white placeholder (uploaded and waited for)

    std::unique_ptr<gpu::Buffer> makeVertices(const BKOverlayList *list, gpu::Status *status);
    // What: one texture per list image (R8 masks / RGBA8 pictures), uploads recorded into `uploads`.
    gpu::Status makeImages(const BKOverlayList *list, gpu::CommandList &uploads, std::vector<std::unique_ptr<gpu::Texture>> *images);

    // What: draws the list into the current pass (colour format `target`, view width x height pixels).
    // images[i] = the list's image i (nullptr = white).
    gpu::Status encode(gpu::CommandList &list, const BKOverlayList *overlay, gpu::Buffer &vertices,
                       gpu::Texture *const *images, uint32_t imageCount, gpu::Format target, uint32_t width, uint32_t height);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace display
}  // namespace boroskit

#endif
#endif
