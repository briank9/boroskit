// BorosKitDisplay: BKOverlayRenderer - see BKOverlayRenderer.h (Metal glue for BKOverlayCore).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly (shaders + per-command state below; GLSL noted).

#import "BKOverlayRenderer.h"
#import "BKMetalDevice.h"
#include "BKOverlayPass.h"   // 2026-11-26: the draw list on the shared GPU interface (Vulkan plan 7.1 #6)
#include "BKGPUMetal.h"
#import "BKGPUEngineBridge.h"   // 2026-11-26: the Vulkan TEST engine (Boros 6 MoltenVK switch)
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
    bkgpu::Device *_vk;                                           // 2026-11-26: Vulkan TEST engine, nullptr = Metal
    std::unique_ptr<boroskit::display::OverlayPass> _vkPass;
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
    _vk = bkgpu::BKGPUTestEngineDevice();   // only when the user chose the Vulkan test engine
    if (_vk) {
        std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
        _vkPass.reset(new boroskit::display::OverlayPass(*_vk));
        if (_vkPass->prepare() != bkgpu::Status::Ok) { _vkPass.reset(); _vk = nullptr; }
    }
    bkgpu::BKGPUEngineLogRenderer("BKOverlayRenderer", _vk != nullptr);
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
    if (_vk) {
        // Vulkan TEST engine: the whole list drawn by the Vulkan OverlayPass over transparent black (premultiplied),
        // read back, and laid over the caller's picture as ONE image (straight alpha, nearest, 1:1) through the Metal
        // pass - the encoder belongs to the caller, so the Vulkan result can only enter as a picture. Within 1 / 255.
        std::vector<uint8_t> layer;
        {
            std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
            double t0 = bkgpu::BKGPUEngineNowMs();
            bkgpu::TextureDesc td;
            td.format = bkgpu::Format::RGBA8Unorm;
            td.width = width; td.height = height;
            td.usage = bkgpu::UsageRenderTarget | bkgpu::UsageCopySource;
            std::unique_ptr<bkgpu::Texture> vkTarget = _vk->makeTexture(td, nullptr);
            std::unique_ptr<bkgpu::Buffer> vkVertices = _vkPass->makeVertices(list, nullptr);
            std::vector<std::unique_ptr<bkgpu::Texture>> vkImages;
            std::unique_ptr<bkgpu::CommandList> up = _vk->begin(nullptr);
            bool ok = vkTarget && vkVertices && up && _vkPass->makeImages(list, *up, &vkImages) == bkgpu::Status::Ok &&
                      _vk->submit(*up, true) == bkgpu::Status::Ok;
            std::vector<bkgpu::Texture *> raw;
            for (auto &t : vkImages) raw.push_back(t.get());
            std::unique_ptr<bkgpu::CommandList> cl = ok ? _vk->begin(nullptr) : nullptr;
            bkgpu::PassTargets pt;
            pt.color[0] = vkTarget.get();   // clear to (0, 0, 0, 0)
            ok = cl && cl->beginPass(pt) == bkgpu::Status::Ok &&
                 _vkPass->encode(*cl, list, *vkVertices, raw.data(), (uint32_t)raw.size(), bkgpu::Format::RGBA8Unorm, width, height) == bkgpu::Status::Ok;
            if (ok) {
                cl->endPass();
                ok = _vk->submit(*cl, true) == bkgpu::Status::Ok && bkgpu::BKGPUReadTexture(*_vk, *vkTarget, &layer);
            }
            if (!ok) {
                if (error) *error = [NSError errorWithDomain:@"BorosKitDisplay" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"The Vulkan test engine could not draw the overlay" }];
                return NO;
            }
            bkgpu::BKGPUEngineLogFrame("BKOverlayRenderer", width, height, bkgpu::BKGPUEngineNowMs() - t0);
        }
        // Premultiplied -> straight alpha (the image command multiplies by alpha again; exact within rounding).
        for (size_t i = 0; i < (size_t)width * height; i++) {
            uint8_t *p = &layer[4 * i];
            if (p[3] == 0) continue;
            for (int k = 0; k < 3; k++) p[k] = (uint8_t)fminf(255.0f, p[k] * 255.0f / p[3] + 0.5f);
        }
        BKOverlayList *one = BKOverlayListCreate();
        int32_t image = BKOverlayAddImage(one, width, height, BKOverlayImageRGBA8, layer.data(), (size_t)width * 4);
        BKOverlayColor white = { 1, 1, 1, 1 };
        BKOverlayDrawImage(one, image, BKV2f(0, 0), BKV2f(1, 0), BKV2f(0, 1), 0, white);
        std::vector<std::unique_ptr<bkgpu::Texture>> holder;
        uint32_t onv = 0;
        const BKOverlayVertex *ov = BKOverlayListVertices(one, &onv);
        MTLTextureDescriptor *otd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        id<MTLTexture> ot = [_device newTextureWithDescriptor:otd];
        [ot replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:layer.data() bytesPerRow:width * 4];
        id<MTLBuffer> ovb = onv ? [_device newBufferWithBytes:ov length:sizeof(BKOverlayVertex) * onv options:MTLResourceStorageModeShared] : nil;
        holder.push_back(ot ? bkgpu::BKGPUMetalWrapTexture(*_gpu, ot) : nullptr);
        bkgpu::Texture *images[1] = { holder.back().get() };
        std::unique_ptr<bkgpu::Buffer> overts = ovb ? bkgpu::BKGPUMetalWrapBuffer(*_gpu, ovb) : nullptr;
        std::unique_ptr<bkgpu::CommandList> mcl = bkgpu::BKGPUMetalCommandListForEncoder(*_gpu, encoder);
        BOOL ok = overts && images[0] && mcl && _pass->encode(*mcl, one, *overts, images, 1, target, width, height) == bkgpu::Status::Ok;
        BKOverlayListFree(one);
        if (!ok && error) *error = [NSError errorWithDomain:@"BorosKitDisplay" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Could not draw the overlay" }];
        return ok;
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
