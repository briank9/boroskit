// BorosKitDisplay: BKOverlayRenderer - draws a BKOverlayCore draw list with Metal (the 2D overlay engine's
// GPU half, overlay-engine plan step 3, 2026-11-16).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Thin Apple glue: everything that decides WHAT is drawn is in
//   BKOverlayCore.c. A Vulkan backend does the same: upload the vertex array (BKOverlayVertex, 32
//   bytes) and the images (RGBA8 / R8), and for each BKOverlayCommand bind the pipeline (normal
//   premultiplied blending, or opaque), the image + sampler (nearest / linear, clamp to edge), set the
//   scissor (the clip, or the whole view) and draw the vertex range as a triangle list. The two shaders
//   are written out below with their GLSL equivalents. Vulkan: flip y (negative viewport height) or
//   keep the y-down conversion in the vertex shader as here.
// - The result must equal BKOverlayRasterize (CPU reference) - checked by BKOverlayRendererTests.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "BKOverlayCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface BKOverlayRenderer : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error;

@property (nonatomic, readonly) id<MTLDevice> device;

// What: draws `list` with an encoder whose colour target (pixel format `format`, viewport
// width x height pixels) already holds the picture underneath (e.g. the 2D image in the frame's
// drawable). The encoder's scissor is left set to the whole view afterwards.
- (BOOL)encodeList:(const BKOverlayList *)list encoder:(id<MTLRenderCommandEncoder>)encoder
       pixelFormat:(MTLPixelFormat)format width:(uint32_t)width height:(uint32_t)height
             error:(NSError **)error;

// What: draws `list` over the existing contents of `texture` (its own render pass, load + store).
- (BOOL)renderList:(const BKOverlayList *)list intoTexture:(id<MTLTexture>)texture
     commandBuffer:(id<MTLCommandBuffer>)commandBuffer error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
