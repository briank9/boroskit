// BorosKitGPU: BKGPUEngine.mm - the GPU engine choice (Metal default / Vulkan test engine) and the bridge helpers.
// See BKGPUEngine.h and BKGPUEngineBridge.h.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Boros 6 MoltenVK test switch). Compiled with ARC.

#import "BKGPUEngine.h"
#import "BKGPUEngineBridge.h"
#import "BKGPUMetal.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#include <atomic>
#include <cstring>
#include <map>

namespace boroskit {
namespace gpu {

namespace {

std::atomic<int> gPreferred(BKGPUEngineMetal);
BKGPUTestEngineFactory gFactory = nullptr;
BKGPUTestEngineProbe gProbe = nullptr;

// The test device: started once, on first need, and kept for the life of the process (renderers keep raw pointers).
struct TestEngine {
    std::once_flag once;
    std::unique_ptr<Device> device;
    std::string description, reason;
};
TestEngine &Engine()
{
    static TestEngine *engine = new TestEngine();   // never destroyed (devices must outlive every renderer)
    return *engine;
}

void StartEngine()
{
    TestEngine &e = Engine();
    std::call_once(e.once, [&e] {
        if (!gFactory) { e.reason = "the app did not register the Vulkan engine"; return; }
        Status s = gFactory(&e.device, &e.description, &e.reason);
        if (s != Status::Ok) e.device.reset();
        os_log(OS_LOG_DEFAULT, "Boros GPU engine: Vulkan test engine %{public}s%{public}s",
               e.device ? "started: " : "NOT available: ", e.device ? e.description.c_str() : e.reason.c_str());
    });
}

uint32_t BytesPerTexel(Format f)
{
    switch (f) {
        case Format::R8Unorm: return 1;
        case Format::R16Unorm: return 2;
        case Format::R32Float: case Format::R32Uint: case Format::RGBA8Unorm: case Format::BGRA8Unorm: return 4;
        case Format::RGBA16Float: return 8;
        case Format::RGBA32Float: return 16;
        case Format::Depth32Float: return 4;
    }
    return 4;
}

// What: the Metal texture's texels in CPU memory (tight rows), via a blit into a shared buffer (waits).
bool ReadMetalTexture(id<MTLTexture> t, uint32_t bytesPerTexel, std::vector<uint8_t> *out)
{
    NSUInteger row = t.width * bytesPerTexel, image = row * t.height, total = image * t.depth;
    id<MTLBuffer> staging = [t.device newBufferWithLength:total options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [t.device newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!staging || !blit) return false;
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, t.depth) toBuffer:staging destinationOffset:0
   destinationBytesPerRow:row destinationBytesPerImage:image];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return false;
    out->assign((const uint8_t *)staging.contents, (const uint8_t *)staging.contents + total);
    return true;
}

// What: a cheap content fingerprint (length + up to 256 sampled 32-bit words) to notice in-place buffer edits.
uint64_t Fingerprint(const uint8_t *bytes, size_t length)
{
    uint64_t h = 1469598103934665603ull ^ length;
    size_t words = length / 4, step = words > 256 ? words / 256 : 1;
    for (size_t i = 0; i < words; i += step) {
        uint32_t w;
        std::memcpy(&w, bytes + 4 * i, 4);
        h = (h ^ w) * 1099511628211ull;
    }
    return h;
}

}  // namespace

void BKGPURegisterTestEngine(BKGPUTestEngineFactory factory, BKGPUTestEngineProbe probe)
{
    gFactory = factory;
    gProbe = probe;
}

Device *BKGPUTestEngineDevice()
{
    if (gPreferred.load() != BKGPUEngineVulkanTest) return nullptr;
    StartEngine();
    return Engine().device.get();
}

std::recursive_mutex &BKGPUTestEngineMutex()
{
    static std::recursive_mutex *m = new std::recursive_mutex();
    return *m;
}

double BKGPUEngineNowMs()
{
    return CACurrentMediaTime() * 1000.0;
}

void BKGPUEngineLogRenderer(const char *who, bool vulkan)
{
    os_log(OS_LOG_DEFAULT, "Boros GPU engine: %{public}s uses %{public}s", who,
           vulkan ? ("Vulkan via MoltenVK (TEST) - " + Engine().description).c_str() : "Metal");
}

void BKGPUEngineLogFrame(const char *who, uint32_t width, uint32_t height, double milliseconds)
{
    static std::mutex m;
    static std::map<std::string, double> last;
    std::lock_guard<std::mutex> lock(m);
    double now = BKGPUEngineNowMs();
    double &t = last[who];
    if (now - t < 1000.0) return;
    t = now;
    os_log(OS_LOG_DEFAULT, "Boros GPU engine: Vulkan frame %{public}s %ux%u %.1f ms (incl. copies)", who, width, height, milliseconds);
}

}  // namespace gpu
}  // namespace boroskit

// Holders for the cached copies (Objective-C objects so NSMapTable can keep them per Metal object).
@interface BKGPUTextureCopyHolder : NSObject {
@public
    std::shared_ptr<boroskit::gpu::Texture> texture;
    boroskit::gpu::Device *device;
}
@end
@implementation BKGPUTextureCopyHolder
@end
@interface BKGPUBufferCopyHolder : NSObject {
@public
    std::shared_ptr<boroskit::gpu::Buffer> buffer;
    boroskit::gpu::Device *device;
    uint64_t fingerprint;
}
@end
@implementation BKGPUBufferCopyHolder
@end

namespace boroskit {
namespace gpu {

std::unique_ptr<Texture> BKGPUMakeTexture(Device &device, const TextureDesc &desc, const void *data, uint32_t bytesPerRow)
{
    std::unique_ptr<Texture> t = device.makeTexture(desc, nullptr);
    if (!t || !data) return t;
    std::unique_ptr<CommandList> list = device.begin(nullptr);
    if (!list || list->upload(*t, data, bytesPerRow, bytesPerRow * desc.height, 0, desc.depth) != Status::Ok ||
        device.submit(*list, true) != Status::Ok)
        return nullptr;
    return t;
}

std::shared_ptr<Texture> BKGPUCopyMetalTexture(Device &device, id<MTLTexture> texture, bool cached)
{
    if (!texture) return nullptr;
    static NSMapTable<id<MTLTexture>, BKGPUTextureCopyHolder *> *cache = [NSMapTable weakToStrongObjectsMapTable];
    @synchronized (cache) {
        BKGPUTextureCopyHolder *held = cached ? [cache objectForKey:texture] : nil;
        if (held && held->device == &device) return held->texture;
        Format format;
        if (!BKGPUMetalFormat(texture.pixelFormat, &format)) return nullptr;
        uint32_t bpt = BytesPerTexel(format);
        std::vector<uint8_t> texels;
        if (!ReadMetalTexture(texture, bpt, &texels)) return nullptr;
        TextureDesc d;
        d.type = texture.textureType == MTLTextureType3D ? TextureType::Texture3D : TextureType::Texture2D;
        d.format = format;
        d.width = (uint32_t)texture.width; d.height = (uint32_t)texture.height; d.depth = (uint32_t)texture.depth;
        d.usage = UsageSampled | UsageCopyDestination | UsageCopySource;
        d.label = "copy of a Metal texture (Vulkan test engine)";
        std::shared_ptr<Texture> copy(BKGPUMakeTexture(device, d, texels.data(), d.width * bpt).release());
        if (copy && cached) {
            BKGPUTextureCopyHolder *h = [[BKGPUTextureCopyHolder alloc] init];
            h->texture = copy;
            h->device = &device;
            [cache setObject:h forKey:texture];
        }
        return copy;
    }
}

std::shared_ptr<Buffer> BKGPUCopyMetalBuffer(Device &device, id<MTLBuffer> buffer)
{
    if (!buffer) return nullptr;
    static NSMapTable<id<MTLBuffer>, BKGPUBufferCopyHolder *> *cache = [NSMapTable weakToStrongObjectsMapTable];
    @synchronized (cache) {
        NSData *bytes = nil;
        if (buffer.storageMode == MTLStorageModePrivate) {   // read it through a blit
            id<MTLBuffer> staging = [buffer.device newBufferWithLength:buffer.length options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [[buffer.device newCommandQueue] commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:buffer sourceOffset:0 toBuffer:staging destinationOffset:0 size:buffer.length];
            [blit endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            bytes = [NSData dataWithBytes:staging.contents length:buffer.length];
        }
        const uint8_t *data = bytes ? (const uint8_t *)bytes.bytes : (const uint8_t *)buffer.contents;
        uint64_t fingerprint = Fingerprint(data, buffer.length);
        BKGPUBufferCopyHolder *held = [cache objectForKey:buffer];
        if (held && held->device == &device && held->fingerprint == fingerprint) return held->buffer;
        std::shared_ptr<Buffer> copy(device.makeBuffer(buffer.length, Memory::Upload, UsageStorage, nullptr).release());
        void *mapped = copy ? copy->map() : nullptr;
        if (!mapped) return nullptr;
        std::memcpy(mapped, data, buffer.length);
        copy->unmap();
        BKGPUBufferCopyHolder *h = [[BKGPUBufferCopyHolder alloc] init];
        h->buffer = copy;
        h->device = &device;
        h->fingerprint = fingerprint;
        [cache setObject:h forKey:buffer];
        return copy;
    }
}

bool BKGPUReadTexture(Device &device, Texture &texture, std::vector<uint8_t> *out)
{
    const TextureDesc &d = texture.desc();
    uint64_t bytes = (uint64_t)d.width * d.height * d.depth * BytesPerTexel(d.format);
    std::unique_ptr<Buffer> rb = device.makeBuffer(bytes, Memory::Readback, UsageCopyDestination, nullptr);
    std::unique_ptr<CommandList> list = rb ? device.begin(nullptr) : nullptr;
    if (!list || list->readback(texture, *rb) != Status::Ok || device.submit(*list, true) != Status::Ok) return false;
    const uint8_t *p = (const uint8_t *)rb->map();
    out->assign(p, p + bytes);
    rb->unmap();
    return true;
}

bool BKGPUBlitBytesToMetalTexture(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture, const void *bytes, size_t bytesPerRow)
{
    if (!commandBuffer || !texture || !bytes) return false;
    id<MTLBuffer> staging = [texture.device newBufferWithBytes:bytes length:bytesPerRow * texture.height
                                                        options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = staging ? [commandBuffer blitCommandEncoder] : nil;
    if (!blit) return false;
    [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:bytesPerRow sourceBytesPerImage:bytesPerRow * texture.height
              sourceSize:MTLSizeMake(texture.width, texture.height, 1) toTexture:texture destinationSlice:0
        destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return true;
}

void BKGPUSwapRedBlue(uint8_t *pixels, size_t pixelCount)
{
    for (size_t i = 0; i < pixelCount; i++) {
        uint8_t r = pixels[4 * i];
        pixels[4 * i] = pixels[4 * i + 2];
        pixels[4 * i + 2] = r;
    }
}

void BKGPUStampTestMarker(uint8_t *pixels, uint32_t width, uint32_t height, bool bgra)
{
    if (width < 40 || height < 16) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = bgra ? (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
                             : (kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, (size_t)width * 4, space, info);
    CGColorSpaceRelease(space);
    if (!ctx) return;
    CGFloat size = height < 200 ? 9 : 12;
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
    CGColorRef yellow = CGColorCreateSRGB(1, 0.85, 0.1, 1);
    NSDictionary *attrs = @{ (__bridge id)kCTFontAttributeName: (__bridge id)font, (__bridge id)kCTForegroundColorAttributeName: (__bridge id)yellow };
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"Vulkan (MoltenVK)" attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    CGRect bounds = CTLineGetImageBounds(line, ctx);
    CGFloat pad = 3, w = bounds.size.width + 2 * pad, h = size + 2 * pad;
    CGFloat x = width - w - 4, y = 4;   // bottom-right (CG origin = bottom-left of the picture)
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 0.75);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
    CGContextSetTextPosition(ctx, x + pad - bounds.origin.x, y + pad + size * 0.2);
    CTLineDraw(line, ctx);
    CFRelease(line);
    CGColorRelease(yellow);
    CFRelease(font);
    CGContextRelease(ctx);
}

id<MTLCommandBuffer> BKGPUFinishedCommandBuffer(id<MTLCommandQueue> queue)
{
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    [cb commit];
    [cb waitUntilCompleted];
    return cb;
}

}  // namespace gpu
}  // namespace boroskit

@implementation BKGPUEngine

+ (void)setPreferredEngine:(BKGPUEngineKind)engine
{
    int previous = boroskit::gpu::gPreferred.exchange((int)engine);
    if (previous != (int)engine)
        os_log(OS_LOG_DEFAULT, "Boros GPU engine preference: %{public}s (new windows)", engine == BKGPUEngineVulkanTest ? "Vulkan via MoltenVK (TEST)" : "Metal");
}

+ (BKGPUEngineKind)preferredEngine
{
    return (BKGPUEngineKind)boroskit::gpu::gPreferred.load();
}

+ (BOOL)vulkanTestEngineAvailable:(NSString **)reason
{
    boroskit::gpu::StartEngine();
    boroskit::gpu::TestEngine &e = boroskit::gpu::Engine();
    if (!e.device && reason) *reason = [NSString stringWithUTF8String:e.reason.c_str()];
    return e.device != nullptr;
}

+ (BOOL)vulkanTestEngineInstalled:(NSString **)reason
{
    std::string why = "the app did not register the Vulkan engine";
    bool ok = boroskit::gpu::gProbe && boroskit::gpu::gProbe(&why);
    if (!ok && reason) *reason = [NSString stringWithUTF8String:why.c_str()];
    return ok;
}

+ (NSString *)currentEngineDescription
{
    if (boroskit::gpu::BKGPUTestEngineDevice())
        return [NSString stringWithFormat:@"Vulkan via MoltenVK (TEST) - %s", boroskit::gpu::Engine().description.c_str()];
    return @"Metal";
}

@end
