// BorosKitDisplay: BKOverlayRenderer - see BKOverlayRenderer.h (Metal glue for BKOverlayCore).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly (shaders + per-command state below; GLSL noted).

#import "BKOverlayRenderer.h"
#import "BKMetalDevice.h"
#include "BKOverlayPass.h"   // 2026-11-26: the draw list on the shared GPU interface (Vulkan plan 7.1 #6)
#include "BKGPUMetal.h"
#include <vector>

namespace bkgpu = boroskit::gpu;

extern "C" NSString *BKOverlayShaderSource(void);   // BKOverlayShaderSource.mm (2026-11-26)

// 2026-11-26 (agent "vulkan-engine"): the per-command drawing is the backend-neutral OverlayPass (shared with the
// Vulkan engine); this class keeps its API, writes the vertices / images into Metal shared memory as before and draws
// into the caller's encoder through the glue.
@implementation BKOverlayRenderer {
    id<MTLLibrary> _library;
    std::unique_ptr<bkgpu::Device> _gpu;
    std::unique_ptr<boroskit::display::OverlayPass> _pass;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device;
    _library = [device newLibraryWithSource:BKOverlayShaderSource() options:[BKMetalDevice shaderCompileOptions] error:error];
    if (!_library) return nil;
    if (bkgpu::makeMetalDevice(device, nil, &_gpu) != bkgpu::Status::Ok || bkgpu::BKGPUMetalAddLibrary(*_gpu, _library) != bkgpu::Status::Ok)
        return nil;
    _pass.reset(new boroskit::display::OverlayPass(*_gpu));
    if (_pass->prepare() != bkgpu::Status::Ok) return nil;
    return self;
}

- (BOOL)encodeList:(const BKOverlayList *)list encoder:(id<MTLRenderCommandEncoder>)encoder
       pixelFormat:(MTLPixelFormat)format width:(uint32_t)width height:(uint32_t)height error:(NSError **)error
{
    uint32_t nv = 0, nc = 0, ni = 0;
    const BKOverlayVertex *v = BKOverlayListVertices(list, &nv);
    BKOverlayListCommands(list, &nc);
    const BKOverlayImage *im = BKOverlayListImages(list, &ni);
    if (nv == 0 || nc == 0 || width == 0 || height == 0) return YES;   // nothing to draw
    bkgpu::Format target;
    if (!bkgpu::BKGPUMetalFormat(format, &target)) {
        if (error) *error = [NSError errorWithDomain:@"BorosKitDisplay" code:4 userInfo:@{ NSLocalizedDescriptionKey: @"Unsupported target pixel format" }];
        return NO;
    }
    std::vector<std::unique_ptr<bkgpu::Texture>> wrapped;
    std::vector<bkgpu::Texture *> images;
    id<MTLBuffer> vb = [_device newBufferWithBytes:v length:sizeof(BKOverlayVertex) * nv options:MTLResourceStorageModeShared];
    for (uint32_t i = 0; i < ni; i++) {
        MTLPixelFormat pf = im[i].kind == BKOverlayImageAlpha8 ? MTLPixelFormatR8Unorm : MTLPixelFormatRGBA8Unorm;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:im[i].width height:im[i].height mipmapped:NO];
        id<MTLTexture> t = [_device newTextureWithDescriptor:td];
        [t replaceRegion:MTLRegionMake2D(0, 0, im[i].width, im[i].height) mipmapLevel:0 withBytes:im[i].pixels
             bytesPerRow:im[i].width * (im[i].kind == BKOverlayImageAlpha8 ? 1 : 4)];
        wrapped.push_back(t ? bkgpu::BKGPUMetalWrapTexture(*_gpu, t) : nullptr);
        images.push_back(wrapped.back().get());   // nullptr = the pass's white
    }
    std::unique_ptr<bkgpu::Buffer> vertices = vb ? bkgpu::BKGPUMetalWrapBuffer(*_gpu, vb) : nullptr;
    std::unique_ptr<bkgpu::CommandList> cl = bkgpu::BKGPUMetalCommandListForEncoder(*_gpu, encoder);
    if (!vertices || !cl ||
        _pass->encode(*cl, list, *vertices, images.data(), (uint32_t)images.size(), target, width, height) != bkgpu::Status::Ok) {
        if (error) *error = [NSError errorWithDomain:@"BorosKitDisplay" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Could not draw the overlay" }];
        return NO;
    }
    return YES;
}

- (BOOL)renderList:(const BKOverlayList *)list intoTexture:(id<MTLTexture>)texture
     commandBuffer:(id<MTLCommandBuffer>)commandBuffer error:(NSError **)error
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    BOOL ok = [self encodeList:list encoder:enc pixelFormat:texture.pixelFormat
                         width:(uint32_t)texture.width height:(uint32_t)texture.height error:error];
    [enc endEncoding];
    return ok;
}

@end
