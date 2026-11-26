// BorosKitRender: BKCurvedReformat - see include/BKCurvedReformat.h (what, why, porting notes).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly - the kernel below mirrors BKCurvedReformatCore.c line by line; the
// comments name the GLSL equivalent of each Metal construct.

#import "BKCurvedReformat.h"
#import "BKVolumeTexture.h"
#import "BKMetalDevice.h"
#include <unistd.h>
#include "BKReformatPass.h"   // 2026-11-26: the picture on the shared GPU interface (Vulkan plan 7.1 #5)
#include "BKGPUMetal.h"

namespace bkgpu = boroskit::gpu;


static NSError *BKReformatError(NSInteger code, NSString *text)
{
    return [NSError errorWithDomain:@"BKCurvedReformat" code:code userInfo:@{ NSLocalizedDescriptionKey: text }];
}

extern "C" NSString *BKReformatShaderSource(void);   // BKReformatShaderSource.mm (2026-11-26)

// 2026-11-26 (agent "vulkan-engine"): a thin Metal adapter over the backend-neutral ReformatPass (shared with the
// Vulkan engine); public API, error codes and memory rules (no-copy page-aligned output) unchanged.
@implementation BKCurvedReformat {
    id<MTLCommandQueue> _queue;
    std::unique_ptr<bkgpu::Device> _gpu;
    std::unique_ptr<boroskit::render::ReformatPass> _pass;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if ((self = [super init])) {
        _device = device ?: MTLCreateSystemDefaultDevice();
        if (_device == nil) {
            if (error) *error = BKReformatError(1, @"No Metal device.");
            return nil;
        }
        id<MTLLibrary> library = [_device newLibraryWithSource:BKReformatShaderSource() options:[BKMetalDevice shaderCompileOptions] error:error];
        _queue = [_device newCommandQueue];
        if (library && _queue && bkgpu::makeMetalDevice(_device, _queue, &_gpu) == bkgpu::Status::Ok &&
            bkgpu::BKGPUMetalAddLibrary(*_gpu, library) == bkgpu::Status::Ok) {
            _pass.reset(new boroskit::render::ReformatPass(*_gpu));
            if (_pass->prepare() != bkgpu::Status::Ok) _pass.reset();
        }
        if (_pass == nullptr || _queue == nil) {
            if (error && *error == nil) *error = BKReformatError(2, @"The curved-MPR kernel could not be built.");
            return nil;
        }
    }
    return self;
}

// What: fills the volume fields of params from the GPU scan.
static BKReformatParams BKReformatWithVolume(BKReformatParams params, BKVolumeTexture *volume)
{
    params.valueScale = volume.valueScale;
    params.valueOffset = volume.valueOffset;
    params.volumeWide = (uint32_t)volume.pixelsWide;
    params.volumeHigh = (uint32_t)volume.pixelsHigh;
    params.volumeDeep = (uint32_t)volume.pixelsDeep;
    return params;
}

- (id<MTLCommandBuffer>)encodeParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                         valueBuffer:(id<MTLBuffer>)valueBuffer error:(NSError **)error
{
    if (volume.texture == nil || frames == NULL || params.width == 0 || params.height == 0 || params.depth == 0) {
        if (error) *error = BKReformatError(3, @"Nothing to draw (no scan, no frames or an empty picture).");
        return nil;
    }
    params = BKReformatWithVolume(params, volume);
    std::unique_ptr<bkgpu::Buffer> frameBuffer = _pass->makeFrames(frames, params.width, nullptr);
    if (frameBuffer == nullptr) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the column frames.");
        return nil;
    }
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    {
        // Recorded through the shared interface (the command buffer keeps the Metal buffers alive until it is done).
        std::unique_ptr<bkgpu::CommandList> list = bkgpu::BKGPUMetalCommandList(*_gpu, cb);
        std::unique_ptr<bkgpu::Texture> scan = bkgpu::BKGPUMetalWrapTexture(*_gpu, volume.texture);
        std::unique_ptr<bkgpu::Buffer> values = bkgpu::BKGPUMetalWrapBuffer(*_gpu, valueBuffer);
        if (!list || !scan || !values || _pass->encode(*list, params, *frameBuffer, *scan, *values) != bkgpu::Status::Ok) {
            if (error) *error = BKReformatError(6, @"The GPU failed to draw the picture.");
            return nil;
        }
    }
    [cb commit];
    return cb;
}

- (BOOL)renderParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                into:(float *)destination capacity:(NSUInteger)capacityBytes error:(NSError **)error
{
    NSUInteger bytes = (NSUInteger)params.width * params.height * sizeof(float);
    if (destination == NULL || capacityBytes < bytes || bytes == 0) {
        if (error) *error = BKReformatError(5, @"The destination is missing or too small.");
        return NO;
    }
    NSUInteger page = (NSUInteger)getpagesize();
    // iOS Simulator (2026-11-24, Boros Mobile): its Metal driver traps on newBufferWithBytesNoCopy over app memory
    // (XPC shared-memory misuse), so the simulator always takes the copy path. Devices and Macs are unchanged.
    BOOL direct = !TARGET_OS_SIMULATOR && ((uintptr_t)destination % page) == 0 && capacityBytes % page == 0;
    id<MTLBuffer> valueBuffer = direct
        ? [_device newBufferWithBytesNoCopy:destination length:capacityBytes options:MTLResourceStorageModeShared deallocator:nil]
        : [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (valueBuffer == nil) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the picture.");
        return NO;
    }
    id<MTLCommandBuffer> cb = [self encodeParams:params frames:frames volume:volume valueBuffer:valueBuffer error:error];
    if (cb == nil) return NO;
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = cb.error ?: BKReformatError(6, @"The GPU failed to draw the picture.");
        return NO;
    }
    if (!direct) memcpy(destination, valueBuffer.contents, bytes);
    return YES;
}

- (id<MTLCommandBuffer>)commitParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                                into:(float *)destination capacity:(NSUInteger)capacityBytes error:(NSError **)error
{
    NSUInteger bytes = (NSUInteger)params.width * params.height * sizeof(float), page = (NSUInteger)getpagesize();
    if (destination == NULL || capacityBytes < bytes || bytes == 0 || ((uintptr_t)destination % page) != 0 || capacityBytes % page != 0 || TARGET_OS_SIMULATOR) {
        // (The iOS Simulator cannot wrap app memory in a Metal buffer: callers use -renderParams: there.)
        if (error) *error = BKReformatError(7, @"Drawing ahead needs page-aligned memory of whole pages (not available in the iOS Simulator).");
        return nil;
    }
    id<MTLBuffer> valueBuffer = [_device newBufferWithBytesNoCopy:destination length:capacityBytes options:MTLResourceStorageModeShared deallocator:nil];
    if (valueBuffer == nil) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the picture.");
        return nil;
    }
    return [self encodeParams:params frames:frames volume:volume valueBuffer:valueBuffer error:error];
}

+ (void)computeOnCPUParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames voxels:(const float *)voxels into:(float *)destination
{
    if (params.height == 0) return;
    const uint32_t block = 16;   // rows per task; any split gives the same pixels
    size_t tasks = (params.height + block - 1) / block;
    BKReformatParams *p = &params;
    dispatch_apply(tasks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t t) {
        uint32_t start = (uint32_t)t * block;
        BKReformatComputeRows(p, frames, voxels, start, MIN(start + block, p->height), destination);
    });
}

@end
