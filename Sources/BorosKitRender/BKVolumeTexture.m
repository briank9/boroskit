// BorosKitRender: BKVolumeTexture implementation (see the header for the storage choice).

#import "BKVolumeTexture.h"
#import "CPRVolumeData.h"
#import <Accelerate/Accelerate.h>

NSErrorDomain const BKRenderErrorDomain = @"BKRenderErrorDomain";

// Makes an NSError in the BorosKitRender domain with a plain-language message.
static NSError *BKMakeError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKRenderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation BKVolumeTexture

- (instancetype)initWithVolumeData:(CPRVolumeData *)volumeData device:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;

    _pixelsWide = volumeData.pixelsWide;
    _pixelsHigh = volumeData.pixelsHigh;
    _pixelsDeep = volumeData.pixelsDeep;
    _volumeTransform = volumeData.volumeTransform;
    _minPixelSpacing = volumeData.minPixelSpacing;
    _outOfBoundsValue = volumeData.outOfBoundsValue;

    if (_pixelsWide == 0 || _pixelsHigh == 0 || _pixelsDeep == 0) {
        if (error) *error = BKMakeError(1, @"The volume is empty.");
        return nil;
    }
    // Metal's limit for 3D textures is 2048 voxels per side on all current GPUs.
    if (_pixelsWide > 2048 || _pixelsHigh > 2048 || _pixelsDeep > 2048) {
        if (error) *error = BKMakeError(2, @"The volume is larger than 2048 voxels on one side, which the GPU cannot hold as one 3D texture.");
        return nil;
    }

    CPRVolumeDataInlineBuffer inlineBuffer;
    if (![volumeData aquireInlineBuffer:&inlineBuffer]) {
        [volumeData releaseInlineBuffer:&inlineBuffer];
        if (error) *error = BKMakeError(3, @"The volume data is no longer valid.");
        return nil;
    }

    BOOL ok = [self uploadFloats:CPRVolumeDataFloatBytes(&inlineBuffer) device:device error:error];
    [volumeData releaseInlineBuffer:&inlineBuffer];
    return ok ? self : nil;
}

// Does the actual work: (1) one pass to find min/max and whether all values are whole
// numbers, (2) pick scale/offset so whole-number data is stored exactly, (3) convert
// to 16-bit in chunks of slices and copy each chunk into a GPU-private texture with a
// blit. Chunking keeps the extra CPU memory small (~64 MB) even for huge volumes, and
// private storage is the fastest for the GPU and works on Intel and Apple-silicon Macs.
- (BOOL)uploadFloats:(const float *)floats device:(id<MTLDevice>)device error:(NSError **)error
{
    const NSUInteger sliceVoxels = _pixelsWide * _pixelsHigh;
    const NSUInteger totalVoxels = sliceVoxels * _pixelsDeep;

    // (1) Range and "all integers?" check.
    float lo = INFINITY, hi = -INFINITY;
    vDSP_minv(floats, 1, &lo, totalVoxels);
    vDSP_maxv(floats, 1, &hi, totalVoxels);
    BOOL integral = YES;
    for (NSUInteger i = 0; i < totalVoxels && integral; i++)
        integral = (floats[i] == floorf(floats[i]));
    _minimumValue = lo;
    _maximumValue = hi;

    // (2) step = real-value size of one 16-bit step. The volume's range is always
    // spread over all 65,536 steps (about 0.03 HU per step for a 2000 HU range).
    // Why not "1 step = 1 HU" for whole-number CT: the GPU rounds the *interpolated*
    // result to the texture's 16-bit precision too, so with 1 HU steps every
    // in-between sample would snap to a whole HU. Spreading the range keeps
    // interpolation ~30x finer, while each stored voxel is still within half a step
    // of its true value, so rounding gives the original whole numbers back exactly.
    float range = hi - lo;
    float step = range > 0 ? range / 65535.0f : 1.0f;
    _lossless = range == 0 || (integral && range <= 65535.0f);
    _valueOffset = lo;
    _valueScale = step * 65535.0f;          // texel 0..1 -> 0..65535 steps -> real value

    // (3) Texture + chunked upload.
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatR16Unorm;
    desc.width = _pixelsWide;
    desc.height = _pixelsHigh;
    desc.depth = _pixelsDeep;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead;
    _texture = [device newTextureWithDescriptor:desc];
    if (!_texture) {
        if (error) *error = BKMakeError(4, @"Not enough GPU memory for this volume.");
        return NO;
    }
    _texture.label = @"BorosKit volume";

    id<MTLCommandQueue> queue = [device newCommandQueue];
    const NSUInteger bytesPerSlice = sliceVoxels * sizeof(uint16_t);
    NSUInteger slicesPerChunk = MAX((NSUInteger)1, (NSUInteger)(64 * 1024 * 1024) / bytesPerSlice);
    slicesPerChunk = MIN(slicesPerChunk, _pixelsDeep);
    id<MTLBuffer> staging = [device newBufferWithLength:slicesPerChunk * bytesPerSlice options:MTLResourceStorageModeShared];
    float *scratch = malloc(sliceVoxels * sizeof(float));
    if (!staging || !scratch) {
        free(scratch);
        if (error) *error = BKMakeError(5, @"Not enough memory to prepare the volume for the GPU.");
        return NO;
    }

    const float negOffset = -lo, invStep = 1.0f / step;
    for (NSUInteger z0 = 0; z0 < _pixelsDeep; z0 += slicesPerChunk) {
        NSUInteger n = MIN(slicesPerChunk, _pixelsDeep - z0);
        uint16_t *dst = staging.contents;
        for (NSUInteger s = 0; s < n; s++) {
            const float *src = floats + (z0 + s) * sliceVoxels;
            // (v - lo) / step, then round to the nearest 16-bit integer.
            vDSP_vsadd(src, 1, &negOffset, scratch, 1, sliceVoxels);
            vDSP_vsmul(scratch, 1, &invStep, scratch, 1, sliceVoxels);
            float zero = 0, top = 65535;
            vDSP_vclip(scratch, 1, &zero, &top, scratch, 1, sliceVoxels);
            vDSP_vfixru16(scratch, 1, dst + s * sliceVoxels, 1, sliceVoxels);
        }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0
           sourceBytesPerRow:_pixelsWide * sizeof(uint16_t) sourceBytesPerImage:bytesPerSlice
                  sourceSize:MTLSizeMake(_pixelsWide, _pixelsHigh, n)
                   toTexture:_texture destinationSlice:0 destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, z0)];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted]; // the staging buffer is reused for the next chunk
        if (cb.status == MTLCommandBufferStatusError) {
            free(scratch);
            if (error) *error = cb.error ?: BKMakeError(6, @"The GPU failed to copy the volume.");
            return NO;
        }
    }
    free(scratch);
    return YES;
}

@end
