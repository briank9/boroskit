// BorosKitGPU: BKGPUEngineBridge.h - the glue that lets a Metal-facing BorosKit renderer run its shared pass on the
// Vulkan TEST engine (see BKGPUEngine.h): the shared test device, copies Metal -> device, read-backs, writing results
// into Metal textures, the on-screen marker and the log.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Boros 6 MoltenVK test switch).
//
// PORTING NOTES:
//   - Objective-C++ only (Apple glue); not part of the backend-neutral code. Everything here is synchronous (copies wait
//     for the GPU): correctness and a fair picture comparison, not speed.
//   - All work on the test device is serialised with BKGPUTestEngineMutex() (one queue, no external sync otherwise).
//   - Cached copies are keyed by the Metal object (weakly): a scan, a mesh buffer or a texture is copied once and reused
//     while that Metal object lives. Buffers are re-copied when a sampled checksum changes (in-place edits).

#ifndef BK_GPU_ENGINE_BRIDGE_H
#define BK_GPU_ENGINE_BRIDGE_H

#if defined(__cplusplus) && defined(__OBJC__)
#import <Metal/Metal.h>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "BKGPU.h"

namespace boroskit {
namespace gpu {

// What the Vulkan backend registers (BKGPUVulkanTestEngineInstall): makes the test device once. Returns Status::Ok
// and the device, or a status + a one-line reason. description: e.g. "Vulkan (MoltenVK) on Apple M1 Pro, loader ...".
typedef Status (*BKGPUTestEngineFactory)(std::unique_ptr<Device> *out, std::string *description, std::string *reason);
void BKGPURegisterTestEngine(BKGPUTestEngineFactory factory);

// What: the shared test device when the preferred engine is the Vulkan test engine and it started; else nullptr
// (the renderer then uses Metal, as always). Call when a renderer is created.
Device *BKGPUTestEngineDevice();
std::recursive_mutex &BKGPUTestEngineMutex();

// What: logs once per renderer class which engine it uses ("Boros GPU engine: <who> uses ...").
void BKGPUEngineLogRenderer(const char *who, bool vulkan);
// What: logs a test-engine frame time, at most once per second per `who`.
void BKGPUEngineLogFrame(const char *who, uint32_t width, uint32_t height, double milliseconds);
double BKGPUEngineNowMs();

// What: a copy of a Metal texture (2D or 3D, a format BKGPU.h names) on `device`, usage sampled. cached = reuse the
// copy while the Metal texture lives (static content: scans, colour tables, images); else a fresh copy.
std::shared_ptr<Texture> BKGPUCopyMetalTexture(Device &device, id<MTLTexture> texture, bool cached);
// What: a copy of a Metal buffer (shared or private) on `device` (Upload memory, usage storage); cached by the buffer,
// re-copied when its sampled checksum changed.
std::shared_ptr<Buffer> BKGPUCopyMetalBuffer(Device &device, id<MTLBuffer> buffer);
// What: the texture's texels, tight rows (slices after each other).
bool BKGPUReadTexture(Device &device, Texture &texture, std::vector<uint8_t> *out);
// What: a texture with initial content (uploaded and waited for). bytesPerRow = tight row of `data` (nullptr = none).
std::unique_ptr<Texture> BKGPUMakeTexture(Device &device, const TextureDesc &desc, const void *data, uint32_t bytesPerRow);
// What: records into `commandBuffer` a copy of `bytes` (tight rows, the texture's own format) into `texture`.
// The texture must allow blits (not framebufferOnly). The staging buffer lives as long as the command buffer.
bool BKGPUBlitBytesToMetalTexture(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture, const void *bytes, size_t bytesPerRow);
// What: swaps R and B of RGBA8 pixels in place (for BGRA8 targets).
void BKGPUSwapRedBlue(uint8_t *pixels, size_t pixelCount);
// What: draws the small "Vulkan (MoltenVK)" marker into premultiplied 8-bit pixels (bottom-right corner).
void BKGPUStampTestMarker(uint8_t *pixels, uint32_t width, uint32_t height, bool bgra);
// What: an already finished, empty command buffer (for APIs that hand back a command buffer to wait on).
id<MTLCommandBuffer> BKGPUFinishedCommandBuffer(id<MTLCommandQueue> queue);

}  // namespace gpu
}  // namespace boroskit

#endif
#endif
