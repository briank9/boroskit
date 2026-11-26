// BorosKitGPU: BKGPUMetal.h - the Metal implementation of BKGPU.h, and its Apple-only glue.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan phase 2: "GPU interface + MetalDevice").
//
// PORTING NOTES:
//   - Objective-C++ only (guarded): this file and BKGPUMetal.mm are the ONLY place where the interface meets Metal.
//     A Windows / Linux build never sees them (they are not in CMake); backend-neutral code (MeshPass ...) uses
//     BKGPU.h alone.
//   - Metal is the REFERENCE backend: every mapping below is chosen so a pass running on this device produces
//     exactly what the hand-written Metal code produced before (checked by the golden harness in strict mode).
//   - Shaders: Metal libraries are compiled from each module's MSL source by that module (as before) and handed to
//     the device with BKGPUMetalAddLibrary; ShaderRef names are looked up in the added libraries.
//   - Interop: existing Metal objects (a CAMetalLayer drawable, a caller's command buffer, buffers a mesh object
//     already uploaded) are WRAPPED, not copied, so the Objective-C classes keep their behaviour and caches.
//   - Bindings: slot n = Metal index n (buffer(n) / texture(n) / sampler(n)) in the stages the SlotLayout names;
//     UniformBlock bytes = setVertexBytes / setFragmentBytes.
//   - Per-draw state Metal keeps on the encoder (cull mode, triangle fill mode, front face, depth-stencil state) is
//     taken from the RenderPipeline at every draw.
//
// Plain language: "speak the shared GPU language on a Mac". The Mac app keeps drawing with Metal exactly as
// before; the drawing code is simply written once and can also run on the Vulkan engine.

#ifndef BK_GPU_METAL_H
#define BK_GPU_METAL_H

#if defined(__cplusplus) && defined(__OBJC__)

#import <Metal/Metal.h>
#include "BKGPU.h"

namespace boroskit {
namespace gpu {

// What: a Device for an existing id<MTLDevice> (nil = BKMetalDevice's preferred GPU). Status::NotFound if none.
Status makeMetalDevice(id<MTLDevice> device, std::unique_ptr<Device> *out);

// What: makes the functions of `library` available to ShaderRef names on `device` (a MetalDevice).
Status BKGPUMetalAddLibrary(Device &device, id<MTLLibrary> library);

// What: wrap existing Metal objects (the wrapper keeps a strong reference; nothing is copied).
// Texture formats that BKGPU.h does not name are refused (nullptr).
std::unique_ptr<Texture> BKGPUMetalWrapTexture(Device &device, id<MTLTexture> texture);
std::unique_ptr<Buffer> BKGPUMetalWrapBuffer(Device &device, id<MTLBuffer> buffer);
// What: a CommandList that records into `commandBuffer`; the caller commits it (Device::submit is not used).
std::unique_ptr<CommandList> BKGPUMetalCommandList(Device &device, id<MTLCommandBuffer> commandBuffer);

// What: the Metal object behind an interface object made by a MetalDevice (nil for others).
id<MTLTexture> BKGPUMetalTexture(Texture &texture);
id<MTLBuffer> BKGPUMetalBuffer(Buffer &buffer);
id<MTLDevice> BKGPUMetalDevice(Device &device);

}  // namespace gpu
}  // namespace boroskit

#endif  // __cplusplus && __OBJC__
#endif  // BK_GPU_METAL_H
