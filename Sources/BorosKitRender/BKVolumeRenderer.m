// BorosKitRender: BKVolumeRenderer implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * This is the main engine that draws the 3D picture of a scan on the computer's
 * graphics chip (GPU), which is much faster than the CPU for this kind of work.
 * It combines the uploaded scan, the colour and opacity rules, the camera and the
 * quality settings, runs the drawing program (the shader) that follows a ray through
 * the scan for each pixel, and returns the finished image.
 * Other parts of the viewer call this each time the 3D picture needs redrawing.
 */

#import "BKVolumeRenderer.h"
#include <unistd.h>   // getpagesize (values-only render into caller memory)
#import "BKVolumeTexture.h"
#import "BKVolumeTexture+Bricks.h"
#import "BKTransferFunction.h"
#import "BKShaderTypes.h"
#import "BKRenderCore.h"
#import "BKRenderParamsCore.h"   // the parameter block in plain C (2026-11-26)
#import "BKVolumeFusionCore.h"   // colour scans + fusion rules (plain C, 2026-11-24)
#import "BKMetalDevice.h"     // the user's chosen graphics card (Automatic by default)
#import "CPRVolumeData.h"

NSString *BKVolumeShaderSource(void); // BKShaderSource.mm

// Number of entries in the transfer-function lookup texture. 4096 gives < 1 HU per
// entry over a typical 4000 HU CT range, so the GPU lookup is as fine as the data.
static const NSUInteger kTransferFunctionEntries = BK_TRANSFER_FUNCTION_ENTRIES;

// Makes an NSError in the BorosKitRender domain with a plain-language message.
static NSError *BKRendererError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKRenderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// What: a float3 widened to the float4 the parameter block stores (w = 0).
// Why: BKRenderParams keeps 3D quantities in float4 so its layout is std430 (Vulkan).
static simd_float4 BKFloat4(simd_float3 v)
{
    return simd_make_float4(v, 0.0f);
}

#pragma mark - BKRenderResult

@interface BKRenderResult ()
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height rgba:(NSData *)rgba floats:(NSData *)floats;
@end

// What: an NSData that reads the GPU buffer's own memory (shared storage) instead of a copy; the
// buffer stays alive until the NSData is released (the deallocator block holds it).
// Why (Boros 6 profile 2026-11-15, curved-MPR scrolling): every slab picture was copied twice after
// the GPU finished (colours + values, ~14 MB each at 3040 x 1192) - ~350 ms of main-thread copying
// per 25 s of scrolling. The buffers are made fresh for each render and never written again, so
// handing them over unchanged is safe.
// Vulkan note: the equivalent is a host-visible, host-coherent VkBuffer kept mapped for the result's
// lifetime (no staging copy).
static NSData *BKDataWrappingBuffer(id<MTLBuffer> buffer, NSUInteger length)
{
    return [[NSData alloc] initWithBytesNoCopy:buffer.contents length:length deallocator:^(void *bytes, NSUInteger size) {
        (void)bytes; (void)size;
        (void)buffer;   // captured: keeps the MTLBuffer (and its memory) alive until now
    }];
}

@implementation BKRenderResult

// Wraps the two output buffers (since 2026-11-15 the GPU buffers themselves, not copies).
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height rgba:(NSData *)rgba floats:(NSData *)floats
{
    if ((self = [super init])) {
        _width = width;
        _height = height;
        _rgba8Data = rgba;
        _floatData = floats;
    }
    return self;
}

- (float)valueAtX:(NSUInteger)x y:(NSUInteger)y
{
    NSParameterAssert(x < _width && y < _height);
    return ((const float *)_floatData.bytes)[y * _width + x];
}

- (void)getRGBA8:(uint8_t[4])rgba atX:(NSUInteger)x y:(NSUInteger)y
{
    NSParameterAssert(x < _width && y < _height);
    memcpy(rgba, (const uint8_t *)_rgba8Data.bytes + 4 * (y * _width + x), 4);
}

// CGImage over the RGBA bytes (premultiplied alpha: composite colour is already
// multiplied by opacity during blending, projection modes are opaque).
- (CGImageRef)newCGImage
{
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)_rgba8Data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(_width, _height, 8, 32, _width * 4, space,
                                     kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

@end

#pragma mark - BKVolumeRenderer

@implementation BKVolumeRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _raycastPipeline;
    id<MTLComputePipelineState> _sizePipeline;
    id<MTLComputePipelineState> _texturePipeline;  // bk_raycast_texture (on-screen output)
    id<MTLComputePipelineState> _upscalePipeline;  // bk_upscale (LOD stretch)
    id<MTLBuffer> _valuesOnlyColorPlaceholder;     // 16-byte stand-in for the RGBA output when only values are written (2026-11-15)
    id<MTLTexture> _tfTexture;            // baked transfer function (4096 x 1, RGBA float)
    BKTransferFunction *_bakedTransferFunction; // which function _tfTexture currently holds
    BKTransferFunction *_defaultTransferFunction; // gray ramp used when none is set

    // --- Empty-space skipping (see BK_BRICK_SIZE in BKShaderTypes.h) ---
    id<MTLComputePipelineState> _brickRangePipeline;    // bk_brick_ranges (once per volume)
    id<MTLComputePipelineState> _classifyPipeline;      // bk_classify_bricks (per transfer function)
    id<MTLBuffer> _alphaCountBuffer;    // running count of non-see-through table entries, per bake
    id<MTLBuffer> _brickEmptyBuffer;    // 1 uint32 per brick: 1 = fully see-through
    id<MTLBuffer> _classifiedAlphaCount;            // which table _brickEmptyBuffer was made for
    __weak BKVolumeTexture *_classifiedVolume;      // ...and which volume
    id<MTLBuffer> _placeholderBuffer;   // bound instead when skipping is off (the GPU wants something there)
    // Embedded objects (2026-11-14): 1 x 1 pictures bound when there are none (every kernel
    // argument must be bound; the shader does not read them then, p.useGeometry == 0).
    id<MTLTexture> _noGeometryColor;
    id<MTLTexture> _noGeometryDistance;

    // --- Fusion (2026-11-24, vr-colour-fusion): the fused scan's baked table and the stand-ins bound without one ---
    id<MTLTexture> _blendTfTexture;              // 4096 x 1 RGBA float, the fused scan's colour / opacity
    BKTransferFunction *_bakedBlendTransferFunction;
    id<MTLTexture> _noBlendVolume;               // 1 x 1 x 1 R16 3D texture bound at slot 5 when nothing is fused

    // --- Extra clipping planes (see -setPackedClipPlanes:count: / -setClipPlanes:count:) ---
    // Kept in the GPU packing (nx, ny, nz, w; cut where n.x + w > 0), so the simd setter needs no
    // conversion and the N3Plane setter converts once with BKClipPlanesPack.
    simd_float4 _clipPlanes[BK_MAX_CLIP_PLANES];
    NSUInteger _clipPlaneCount;
}

// Both accessors are custom (they copy), so the backing variable must be declared explicitly.
@synthesize transferFunction = _transferFunction;
@synthesize blendTransferFunction = _blendTransferFunction;

// Compiles the shader library once per GPU and shares it between renderers, since
// compiling is the slow part of creating a renderer.
+ (id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device error:(NSError **)error
{
    static NSMapTable<id<MTLDevice>, id<MTLLibrary>> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized (cache) {
        id<MTLLibrary> library = [cache objectForKey:device];
        if (!library) {
            MTLCompileOptions *options = [BKMetalDevice shaderCompileOptions];   // fast math off (2026-11-14)
            library = [device newLibraryWithSource:BKVolumeShaderSource() options:options error:error];
            if (library) [cache setObject:library forKey:device];
        }
        return library;
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device ?: [BKMetalDevice preferredDevice];   // no device given: the preferred card, see BKMetalDevice.h
    if (!_device) {
        if (error) *error = BKRendererError(10, @"No Metal GPU is available on this device.");
        return nil;
    }
    id<MTLLibrary> library = [[self class] libraryForDevice:_device error:error];
    if (!library) return nil;
    _raycastPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_raycast"] error:error];
    _sizePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_params_size"] error:error];
    _texturePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_raycast_texture"] error:error];
    _upscalePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_upscale"] error:error];
    _brickRangePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_brick_ranges"] error:error];
    _classifyPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_classify_bricks"] error:error];
    if (!_raycastPipeline || !_sizePipeline || !_texturePipeline || !_upscalePipeline
        || !_brickRangePipeline || !_classifyPipeline) return nil;
    _placeholderBuffer = [_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    _noGeometryColor = [_device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO]];
    _noGeometryDistance = [_device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO]];
    if (!_noGeometryColor || !_noGeometryDistance) return nil;
    MTLTextureDescriptor *noBlend = [[MTLTextureDescriptor alloc] init];
    noBlend.textureType = MTLTextureType3D;
    noBlend.pixelFormat = MTLPixelFormatR16Unorm;
    noBlend.width = noBlend.height = noBlend.depth = 1;
    _noBlendVolume = [_device newTextureWithDescriptor:noBlend];
    if (!_noBlendVolume) return nil;
    _blendOpacityUnitDistance = 1;
    _queue = [_device newCommandQueue];

    // Defaults (documented in the header).
    _mode = BKRenderModeComposite;
    _projection = BKProjectionOrthographic;
    _cameraPosition = N3VectorZero;
    _cameraDirection = N3VectorMake(0, 1, 0);   // looking from the front (anterior -> posterior)
    _cameraUp = N3VectorMake(0, 0, 1);          // head up
    _viewWidth = _viewHeight = 100;
    _fieldOfView = 30;
    _slabPlane = N3PlaneMake(N3VectorZero, N3VectorMake(0, 0, 1));
    _windowCenter = 40;
    _windowWidth = 400;
    _opacityUnitDistance = 1;
    _shadingEnabled = YES;
    _ambient = 0.2f;
    _diffuse = 0.8f;
    _specular = 0.2f;
    _specularPower = 10;
    _missValue = NAN;                           // NAN = use the volume's outOfBoundsValue
    _clipPlane = N3PlaneMake(N3VectorZero, N3VectorMake(0, 0, 1));
    _skipsEmptySpace = YES;   // same picture, only faster (proven by the image-equality tests)
    // The colour table is RGBA32Float and is sampled with linear filtering, which some GPUs
    // (e.g. older iPads) cannot do; there the hand-written filter is the only correct path.
    if (@available(macOS 11.0, iOS 14.0, *))
        _manualFiltering = !_device.supports32BitFloatFiltering;
    return self;
}

- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError **)error
{
    BKVolumeTexture *texture = [[BKVolumeTexture alloc] initWithVolumeData:volumeData device:_device error:error];
    if (!texture) return NO;
    self.volumeTexture = texture;
    return YES;
}

// Setting a volume (uploaded here or shared from another renderer) resets cropping to
// the whole volume so a stale crop box from a previous study can never hide data.
- (void)setVolumeTexture:(BKVolumeTexture *)volumeTexture
{
    _volumeTexture = volumeTexture;
    _defaultTransferFunction = nil; // its range depends on the volume
    _cropMin = N3VectorZero;
    if (volumeTexture)
        _cropMax = N3VectorMake(volumeTexture.pixelsWide - 1, volumeTexture.pixelsHigh - 1, volumeTexture.pixelsDeep - 1);
    // Why: same reason as the crop box above - planes from a previous study must not cut the new one.
    _clipPlaneCount = 0;
}

// What: stores up to BK_MAX_CLIP_PLANES clipping planes (patient mm, normal side cut away).
// Why: the 3D window's cropping box can be rotated, which an axis-aligned voxel crop box
// cannot express; 6 arbitrary planes can. Extra planes beyond the maximum are ignored.
// (Kept for existing callers; new code uses the simd form -setPackedClipPlanes:count:.)
- (void)setClipPlanes:(const N3Plane *)planes count:(NSUInteger)count
{
    float packed[4 * BK_MAX_CLIP_PLANES];
    NSUInteger n = planes ? BKClipPlanesPack(planes, count, packed) : 0;
    _clipPlaneCount = n;
    for (NSUInteger i = 0; i < n; i++)
        _clipPlanes[i] = simd_make_float4(packed[4 * i], packed[4 * i + 1], packed[4 * i + 2], packed[4 * i + 3]);
}

// What: the same planes given directly in the GPU packing (simd float4 each: unit normal xyz and
// w = -dot(normal, point on the plane); cut where n.x + w > 0), e.g. from BKBoxClipPlanes.
// Why (2026-11-14): the native cropping box works with simd types only (no Horos-derived
// N3Plane), and the packing is what a Metal or Vulkan shader reads. Planes with a (near) zero
// normal are skipped; normals are made unit length.
- (void)setPackedClipPlanes:(const simd_float4 *)planes count:(NSUInteger)count
{
    _clipPlaneCount = 0;
    for (NSUInteger i = 0; planes && i < count && _clipPlaneCount < BK_MAX_CLIP_PLANES; i++) {
        simd_float3 n = planes[i].xyz;
        float len = simd_length(n);
        if (!(len > 1e-12f)) continue;
        _clipPlanes[_clipPlaneCount++] = planes[i] / len;   // scales w with the normal: same plane
    }
}

// What: number of planes stored by -setClipPlanes:count: / -setPackedClipPlanes:count:.
- (NSUInteger)clipPlaneCount
{
    return _clipPlaneCount;
}

// What: one stored plane (index < clipPlaneCount) in the GPU packing, for callers that compare
// before re-setting. Zero for an index out of range.
- (simd_float4)packedClipPlaneAtIndex:(NSUInteger)index
{
    return index < _clipPlaneCount ? _clipPlanes[index] : simd_make_float4(0, 0, 0, 0);
}

// What: one stored plane as N3Plane (the point on the plane nearest the origin, unit normal).
- (N3Plane)clipPlaneAtIndex:(NSUInteger)index
{
    if (index >= _clipPlaneCount) return N3PlaneMake(N3VectorZero, N3VectorZero);
    simd_float4 p = _clipPlanes[index];
    N3Vector normal = N3VectorMake(p.x, p.y, p.z);
    return N3PlaneMake(N3VectorScalarMultiply(normal, -p.w), normal);
}

// Re-bakes the transfer function into the GPU lookup texture only when it changed,
// because uploading 4096 entries every frame would be wasted work.
- (BKTransferFunction *)effectiveTransferFunction
{
    BKTransferFunction *tf = _transferFunction;
    if (!tf || (tf.colorPointCount == 0 && tf.opacityPointCount == 0)) {
        // Keep one default per volume so it is not rebuilt (and re-uploaded) each frame.
        if (!_defaultTransferFunction)
            _defaultTransferFunction = [BKTransferFunction grayscaleRampFromValue:_volumeTexture.minimumValue toValue:_volumeTexture.maximumValue];
        tf = _defaultTransferFunction;
    }
    return tf;
}

- (void)updateTransferFunctionTexture:(BKTransferFunction *)tf
{
    if (_tfTexture && _bakedTransferFunction == tf) return;
    if (!_tfTexture) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                         width:kTransferFunctionEntries height:1 mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
#if TARGET_OS_OSX
        if (!_device.hasUnifiedMemory) desc.storageMode = MTLStorageModeManaged; // Intel Macs
#endif
        _tfTexture = [_device newTextureWithDescriptor:desc];
    }
    float *rgba = malloc(kTransferFunctionEntries * 4 * sizeof(float));
    [tf bakeIntoRGBA:rgba count:kTransferFunctionEntries];
    [_tfTexture replaceRegion:MTLRegionMake2D(0, 0, kTransferFunctionEntries, 1) mipmapLevel:0
                    withBytes:rgba bytesPerRow:kTransferFunctionEntries * 4 * sizeof(float)];

    // For empty-space skipping: count[k] = how many of the first k entries have any
    // opacity at all (the shader skips only where the ray would find opacity exactly 0).
    // A NEW buffer every time, so a frame still being drawn on the GPU keeps reading
    // the old one undisturbed.
    _alphaCountBuffer = [_device newBufferWithLength:(kTransferFunctionEntries + 1) * sizeof(uint32_t)
                                             options:MTLResourceStorageModeShared];
    BKRenderAlphaPrefixCount(rgba, kTransferFunctionEntries, _alphaCountBuffer.contents);   // plain-C core
    free(rgba);
    _bakedTransferFunction = tf;
}

// The user may set a function and then keep editing it; take a private copy so the
// "changed?" check above is reliable.
- (void)setTransferFunction:(BKTransferFunction *)transferFunction
{
    _transferFunction = [transferFunction copy];
}

// Hands out a copy too, so editing the returned object cannot silently change the
// renderer's function without the texture being re-baked (set it back to apply).
- (BKTransferFunction *)transferFunction
{
    return [_transferFunction copy];
}

#pragma mark - Fusion (2026-11-24, vr-colour-fusion)

- (void)setBlendTransferFunction:(BKTransferFunction *)blendTransferFunction
{
    _blendTransferFunction = [blendTransferFunction copy];   // private copy: the "changed?" check stays reliable
}

- (BKTransferFunction *)blendTransferFunction
{
    return [_blendTransferFunction copy];
}

// What: the classic fused-scan look as a transfer function (see the header).
- (void)setBlendColorTableRed:(const uint8_t *)red green:(const uint8_t *)green blue:(const uint8_t *)blue
                    opacities:(const float *)opacities windowLow:(float)windowLow windowHigh:(float)windowHigh
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    if (!(windowHigh > windowLow)) windowHigh = windowLow + 1e-3f;
    for (int32_t i = 0; i < 255; i++) {
        float v = BKFusionTableEntryValue(windowLow, windowHigh, i);   // plain-C core
        float g = (float)i / 255.0f;
        [tf addColorPointAtValue:v red:red ? red[i] / 255.0f : g green:green ? green[i] / 255.0f : g blue:blue ? blue[i] / 255.0f : g];
        [tf addOpacityPointAtValue:v opacity:opacities ? opacities[i] : 0];
    }
    _blendTransferFunction = tf;
}

// What: the fused scan's table on the GPU, re-baked only when the function changed. nil when nothing is fused.
- (id<MTLTexture>)bakedBlendTable
{
    BKTransferFunction *tf = _blendTransferFunction;
    if (!_blendVolumeTexture || !tf) return nil;
    if (_blendTfTexture && _bakedBlendTransferFunction == tf) return _blendTfTexture;
    // A NEW texture every time, so a frame still being drawn keeps reading the old one (rare: slider / window moves).
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                     width:kTransferFunctionEntries height:1 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
#if TARGET_OS_OSX
    if (!_device.hasUnifiedMemory) desc.storageMode = MTLStorageModeManaged;
#endif
    id<MTLTexture> texture = [_device newTextureWithDescriptor:desc];
    if (!texture) return nil;
    float *rgba = malloc(kTransferFunctionEntries * 4 * sizeof(float));
    [tf bakeIntoRGBA:rgba count:kTransferFunctionEntries];
    [texture replaceRegion:MTLRegionMake2D(0, 0, kTransferFunctionEntries, 1) mipmapLevel:0
                 withBytes:rgba bytesPerRow:kTransferFunctionEntries * 4 * sizeof(float)];
    free(rgba);
    _blendTfTexture = texture;
    _bakedBlendTransferFunction = tf;
    return texture;
}

// What: YES when a fused scan is set up completely (volume + table) and lives on this renderer's device.
- (BOOL)hasBlend
{
    return _blendVolumeTexture && _blendTransferFunction && _blendVolumeTexture.texture.device == _device;
}

// What: binds the fused scan (or the stand-ins) at the kernels' slots 5 and 6.
- (void)bindBlendToEncoder:(id<MTLComputeCommandEncoder>)enc
{
    id<MTLTexture> table = [self hasBlend] ? [self bakedBlendTable] : nil;
    [enc setTexture:table ? _blendVolumeTexture.texture : _noBlendVolume atIndex:5];
    [enc setTexture:table ?: _tfTexture atIndex:6];
}

// What: Apple's simd_normalize, handed to the plain-C params builder so the Mac keeps its exact numbers.
// Why (2026-11-26, agent "vulkan-engine"): simd_normalize uses the CPU's hardware 1/sqrt estimate, which no portable
// formula reproduces bit for bit (see BKRenderParamsCore.h); other platforms use BKRenderNormalize3fPortable.
static void BKSimdNormalize3f(float v[3])
{
    simd_float3 n = simd_normalize(simd_make_float3(v[0], v[1], v[2]));
    v[0] = n.x; v[1] = n.y; v[2] = n.z;
}

// What: an N3AffineTransform (row-vector convention, voxel.x = p.x*m11 + p.y*m21 + p.z*m31 + m41) as the column-major
// matrix of the plain-C core: column c = row c of the N3 matrix.
static void BKColumnMajor(N3AffineTransform m, double out[16])
{
    const double rows[4][4] = { { m.m11, m.m12, m.m13, m.m14 }, { m.m21, m.m22, m.m23, m.m24 },
                                { m.m31, m.m32, m.m33, m.m34 }, { m.m41, m.m42, m.m43, m.m44 } };
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) out[c * 4 + r] = rows[c][r];
}

static void BKVector3(N3Vector v, double out[3])
{
    out[0] = v.x; out[1] = v.y; out[2] = v.z;
}

// Fills the GPU parameter block from the current settings. Since 2026-11-26 (Vulkan plan 7.1 #4a) the arithmetic is
// the plain-C core BKRenderParamsFill (shared with the Vulkan engine); this method only gathers the settings.
- (BOOL)fillParams:(BKRenderParams *)p width:(NSUInteger)width height:(NSUInteger)height
                tf:(BKTransferFunction *)tf error:(NSError **)error
{
    BKVolumeTexture *vt = _volumeTexture;
    BKRenderSettings s;
    memset(&s, 0, sizeof s);
    s.volumeSize[0] = (uint32_t)vt.pixelsWide;
    s.volumeSize[1] = (uint32_t)vt.pixelsHigh;
    s.volumeSize[2] = (uint32_t)vt.pixelsDeep;
    BKColumnMajor(vt.volumeTransform, s.patientToVoxel);
    s.minPixelSpacing = vt.minPixelSpacing;
    s.valueScale = vt.valueScale;
    s.valueOffset = vt.valueOffset;
    s.outOfBoundsValue = vt.outOfBoundsValue;
    s.colorVolume = vt.color ? 1 : 0;
    s.mode = _mode;
    s.projection = _projection;
    BKVector3(_cameraPosition, s.cameraPosition);
    BKVector3(_cameraDirection, s.cameraDirection);
    BKVector3(_cameraUp, s.cameraUp);
    s.viewWidth = _viewWidth;
    s.viewHeight = _viewHeight;
    s.fieldOfView = _fieldOfView;
    s.sampleSpacing = _sampleSpacing;
    BKVector3(_cropMin, s.cropMin);
    BKVector3(_cropMax, s.cropMax);
    s.slabEnabled = _slabEnabled ? 1 : 0;
    BKVector3(_slabPlane.point, s.slabPoint);
    BKVector3(_slabPlane.normal, s.slabNormal);
    s.slabThickness = _slabThickness;
    s.clipPlaneEnabled = _clipPlaneEnabled ? 1 : 0;
    BKVector3(_clipPlane.point, s.clipPoint);
    BKVector3(_clipPlane.normal, s.clipNormal);
    for (NSUInteger i = 0; i < _clipPlaneCount; i++) {
        s.clipPlanes[4 * i + 0] = _clipPlanes[i].x;
        s.clipPlanes[4 * i + 1] = _clipPlanes[i].y;
        s.clipPlanes[4 * i + 2] = _clipPlanes[i].z;
        s.clipPlanes[4 * i + 3] = _clipPlanes[i].w;
    }
    s.clipPlaneCount = (uint32_t)_clipPlaneCount;
    s.tfMin = tf.minimumValue;
    s.tfMax = tf.maximumValue;
    s.windowCenter = _windowCenter;
    s.windowWidth = _windowWidth;
    s.missValue = _missValue;
    s.opacityUnitDistance = _opacityUnitDistance;
    s.shading = _shadingEnabled ? 1 : 0;
    s.ambient = _ambient;
    s.diffuse = _diffuse;
    s.specular = _specular;
    s.specularPower = _specularPower;
    s.manualFiltering = _manualFiltering ? 1 : 0;
    s.useGeometry = [self hasGeometry] ? 1 : 0;   // embedded objects (2026-11-14)
    s.colorUsesTable = _colorChannelsUseTableColors ? 1 : 0;
    s.blendOpacityUnitDistance = _blendOpacityUnitDistance;
    // Fused scan (2026-11-24): only when it is set up completely and its table could be baked.
    if ([self hasBlend] && [self bakedBlendTable]) {
        BKVolumeTexture *bt = _blendVolumeTexture;
        BKTransferFunction *btf = _blendTransferFunction;
        s.useBlend = 1;
        BKColumnMajor(bt.volumeTransform, s.blendPatientToVoxel);
        s.blendVolumeSize[0] = (uint32_t)bt.pixelsWide;
        s.blendVolumeSize[1] = (uint32_t)bt.pixelsHigh;
        s.blendVolumeSize[2] = (uint32_t)bt.pixelsDeep;
        s.blendValueScale = bt.valueScale;
        s.blendValueOffset = bt.valueOffset;
        s.blendTfMin = btf.minimumValue;
        s.blendTfMax = btf.maximumValue;
        s.blendColorVolume = bt.color ? 1 : 0;
    }
    s.normalize3f = BKSimdNormalize3f;   // the Mac's exact numbers (see BKRenderParamsCore.h)

    int code = BKRenderParamsFill(&s, (uint32_t)width, (uint32_t)height, p);
    if (code == BKRenderParamsZeroDirection) {
        if (error) *error = BKRendererError(11, @"The camera direction is zero.");
        return NO;
    }
    if (code == BKRenderParamsUpParallel) {
        if (error) *error = BKRendererError(12, @"The camera up vector is parallel to the viewing direction.");
        return NO;
    }
    return YES;
}

#pragma mark - Embedded objects

// What: YES when both object pictures are set, are the same size and have the right formats.
// Why: a half-set or mismatched pair would read garbage on the GPU; it is ignored instead.
- (BOOL)hasGeometry
{
    id<MTLTexture> c = _geometryColorTexture, d = _geometryRayDistanceTexture;
    return c && d && c.width == d.width && c.height == d.height && d.pixelFormat == MTLPixelFormatR32Float
        && c.width > 0 && c.height > 0;
}

// What: binds the object pictures (or the 1 x 1 placeholders) at the kernels' slots 3 and 4.
- (void)bindGeometryToEncoder:(id<MTLComputeCommandEncoder>)enc
{
    BOOL has = [self hasGeometry];
    [enc setTexture:has ? _geometryColorTexture : _noGeometryColor atIndex:3];
    [enc setTexture:has ? _geometryRayDistanceTexture : _noGeometryDistance atIndex:4];
}

#pragma mark - Empty-space skipping

// Number of bricks along each axis of `vt` (a partial brick at the end counts).
static simd_float3 BKBrickGrid(BKVolumeTexture *vt)
{
    uint32_t g[3];
    BKRenderBrickGrid((uint32_t)vt.pixelsWide, (uint32_t)vt.pixelsHigh, (uint32_t)vt.pixelsDeep, BK_BRICK_SIZE, g);   // plain-C core
    return simd_make_float3(g[0], g[1], g[2]);
}

// What: makes sure the volume's per-brick (lowest, highest) list exists; builds it on
// the GPU the first time and waits for it.
// Why wait: it is done once per volume (a few milliseconds), and waiting means every
// renderer sharing the volume can use the list at once without any ordering worries.
- (id<MTLBuffer>)brickRangesForVolume:(BKVolumeTexture *)vt
{
    @synchronized (vt) {
        if (vt.brickRangeBuffer) return vt.brickRangeBuffer;
        simd_float3 g = BKBrickGrid(vt);
        simd_uint4 grid = simd_make_uint4((uint32_t)g.x, (uint32_t)g.y, (uint32_t)g.z, 0);   // uint4: no 3-vectors in GPU data
        NSUInteger bricks = (NSUInteger)grid.x * grid.y * grid.z;
        // One 32-bit word per brick: lowest | highest << 16 (raw 16-bit steps).
        id<MTLBuffer> ranges = [_device newBufferWithLength:bricks * sizeof(uint32_t) options:MTLResourceStorageModePrivate];
        if (!ranges) return nil;
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:_brickRangePipeline];
        [enc setTexture:vt.texture atIndex:0];
        [enc setBuffer:ranges offset:0 atIndex:0];
        [enc setBytes:&grid length:sizeof(grid) atIndex:1];
        [enc dispatchThreadgroups:MTLSizeMake((grid.x + 3) / 4, (grid.y + 3) / 4, (grid.z + 3) / 4)
            threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status == MTLCommandBufferStatusError) return nil;
        vt.brickRangeBuffer = ranges;
        return ranges;
    }
}

// What: prepares empty-space skipping for one render and tells the shader whether to
// use it (params->skipEmptySpace). In 3D (composite) mode it also re-decides which
// bricks are fully see-through whenever the transfer function or volume changed,
// encoded into `commandBuffer` ahead of the ray casting.
// Returns the two per-brick lists to bind (placeholders when skipping is off).
// Why it can never change the picture: see the shader; skipped samples are exactly the
// ones whose contribution would have been thrown away.
- (void)prepareSkippingForParams:(BKRenderParams *)params
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      brickEmpty:(id<MTLBuffer> __strong *)brickEmpty
                      brickRange:(id<MTLBuffer> __strong *)brickRange
{
    *brickEmpty = _placeholderBuffer;
    *brickRange = _placeholderBuffer;
    params->skipEmptySpace = 0;
    // The average along the ray needs every sample, so nothing to skip there.
    if (!_skipsEmptySpace || _mode == BKRenderModeAverage) return;
    // Colour scans and fusion (2026-11-24): the bricks describe only a grey first scan, so no skipping (the shader's
    // colour / fusion path never reads them).
    if (params->colorVolume != 0 || params->useBlend != 0) return;

    BKVolumeTexture *vt = _volumeTexture;
    id<MTLBuffer> ranges = [self brickRangesForVolume:vt];
    if (!ranges) return;   // could not build the list: just render without skipping
    params->brickGrid = BKFloat4(BKBrickGrid(vt));

    if (_mode == BKRenderModeComposite) {
        if (_classifiedAlphaCount != _alphaCountBuffer || _classifiedVolume != vt || !_brickEmptyBuffer) {
            NSUInteger bricks = (NSUInteger)params->brickGrid.x * (NSUInteger)params->brickGrid.y * (NSUInteger)params->brickGrid.z;
            // A new list each time (rare: only when the colours/opacity change), so a
            // frame still in flight keeps the list it started with.
            // One 32-bit word per brick (GPU buffers hold only 32-bit words: no optional
            // 8-bit storage feature needed in Vulkan; a 512^3 scan has 262,144 bricks = 1 MB).
            id<MTLBuffer> empty = [_device newBufferWithLength:bricks * sizeof(uint32_t) options:MTLResourceStorageModePrivate];
            if (!empty) return;
            id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
            [enc setComputePipelineState:_classifyPipeline];
            [enc setBuffer:ranges offset:0 atIndex:0];
            [enc setBuffer:_alphaCountBuffer offset:0 atIndex:1];
            [enc setBuffer:empty offset:0 atIndex:2];
            [enc setBytes:params length:sizeof(*params) atIndex:3];
            [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)params->brickGrid.x + 3) / 4,
                                                  ((NSUInteger)params->brickGrid.y + 3) / 4,
                                                  ((NSUInteger)params->brickGrid.z + 3) / 4)
                threadsPerThreadgroup:MTLSizeMake(4, 4, 4)];
            [enc endEncoding];
            _brickEmptyBuffer = empty;
            _classifiedAlphaCount = _alphaCountBuffer;
            _classifiedVolume = vt;
        }
        *brickEmpty = _brickEmptyBuffer;
    }
    *brickRange = ranges;
    params->skipEmptySpace = 1;
}

// What: encodes + runs the CPU-readable ray cast into `colorBuffer` / `valueBuffer` and waits for it.
// `valuesOnly` = the kernel skips the RGBA picture (colorBuffer may then be a tiny placeholder).
// Shared by -renderWithWidth:... and -renderValuesInto:... .
- (id<MTLCommandBuffer>)commitRaycastWidth:(NSUInteger)width height:(NSUInteger)height
                               colorBuffer:(id<MTLBuffer>)colorBuffer valueBuffer:(id<MTLBuffer>)valueBuffer
                                valuesOnly:(BOOL)valuesOnly error:(NSError **)error
{
    BKTransferFunction *tf = [self effectiveTransferFunction];
    [self updateTransferFunctionTexture:tf];

    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return nil;
    params.valuesOnly = valuesOnly ? 1 : 0;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLBuffer> brickEmpty, brickRange;
    [self prepareSkippingForParams:&params commandBuffer:cb brickEmpty:&brickEmpty brickRange:&brickRange];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_raycastPipeline];
    [enc setTexture:_volumeTexture.texture atIndex:0];
    [enc setTexture:_tfTexture atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBuffer:colorBuffer offset:0 atIndex:1];
    [enc setBuffer:valueBuffer offset:0 atIndex:2];
    [enc setBuffer:brickEmpty offset:0 atIndex:3];
    [enc setBuffer:brickRange offset:0 atIndex:4];
    [self bindGeometryToEncoder:enc];   // embedded objects (2026-11-14)
    [self bindBlendToEncoder:enc];      // fused scan (2026-11-24)
    // 8x8 tiles: neighbouring rays read neighbouring voxels, which keeps the texture
    // cache warm. Thread groups are dispatched to cover the image; the kernel skips
    // threads that fall outside it.
    MTLSize group = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [enc dispatchThreadgroups:groups threadsPerThreadgroup:group];
    [enc endEncoding];
    [cb commit];
    return cb;
}

// What: the same, waiting for the GPU (the synchronous renders).
- (BOOL)runRaycastWidth:(NSUInteger)width height:(NSUInteger)height
            colorBuffer:(id<MTLBuffer>)colorBuffer valueBuffer:(id<MTLBuffer>)valueBuffer
             valuesOnly:(BOOL)valuesOnly error:(NSError **)error
{
    id<MTLCommandBuffer> cb = [self commitRaycastWidth:width height:height colorBuffer:colorBuffer
                                           valueBuffer:valueBuffer valuesOnly:valuesOnly error:error];
    if (cb == nil) return NO;
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) {
        if (error) *error = cb.error ?: BKRendererError(16, @"The GPU failed to render the image.");
        return NO;
    }
    return YES;
}

- (BKRenderResult *)renderWithWidth:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error
{
    if (!_volumeTexture) {
        if (error) *error = BKRendererError(13, @"No volume has been set.");
        return nil;
    }
    if (width == 0 || height == 0) {
        if (error) *error = BKRendererError(14, @"The output image size is zero.");
        return nil;
    }

    NSUInteger pixels = width * height;
    id<MTLBuffer> colorBuffer = [_device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> valueBuffer = [_device newBufferWithLength:pixels * sizeof(float) options:MTLResourceStorageModeShared];
    if (!colorBuffer || !valueBuffer) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the output image.");
        return nil;
    }
    if (![self runRaycastWidth:width height:height colorBuffer:colorBuffer valueBuffer:valueBuffer
                    valuesOnly:NO error:error])
        return nil;

    return [[BKRenderResult alloc] initWithWidth:width height:height
                                            rgba:BKDataWrappingBuffer(colorBuffer, pixels * 4)
                                          floats:BKDataWrappingBuffer(valueBuffer, pixels * sizeof(float))];
}

- (BOOL)renderValuesInto:(float *)destination capacity:(NSUInteger)capacityBytes
                   width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error
{
    if (!_volumeTexture) {
        if (error) *error = BKRendererError(13, @"No volume has been set.");
        return NO;
    }
    NSUInteger bytes = width * height * sizeof(float);
    if (width == 0 || height == 0 || destination == NULL || capacityBytes < bytes) {
        if (error) *error = BKRendererError(14, @"The output image size is zero or the destination is too small.");
        return NO;
    }

    // The GPU writes straight into `destination` when Metal can use that memory as is: page-aligned
    // start and a whole number of pages (the caller allocates it that way, see the header).
    // Otherwise: one GPU buffer and one copy at the end (same result).
    NSUInteger page = (NSUInteger)getpagesize();
    // iOS Simulator (2026-11-24, Boros Mobile): its Metal driver traps on newBufferWithBytesNoCopy over app memory
    // (XPC shared-memory misuse), so the simulator always takes the copy path. Devices and Macs are unchanged.
    BOOL direct = !TARGET_OS_SIMULATOR && ((uintptr_t)destination % page) == 0 && capacityBytes % page == 0;
    id<MTLBuffer> valueBuffer = direct
        ? [_device newBufferWithBytesNoCopy:destination length:capacityBytes options:MTLResourceStorageModeShared deallocator:nil]
        : [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (_valuesOnlyColorPlaceholder == nil)
        _valuesOnlyColorPlaceholder = [_device newBufferWithLength:16 options:MTLResourceStorageModePrivate];
    if (!valueBuffer || !_valuesOnlyColorPlaceholder) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the output image.");
        return NO;
    }
    if (![self runRaycastWidth:width height:height colorBuffer:_valuesOnlyColorPlaceholder valueBuffer:valueBuffer
                    valuesOnly:YES error:error])
        return NO;
    if (!direct)
        memcpy(destination, valueBuffer.contents, bytes);
    return YES;
}

- (id<MTLCommandBuffer>)commitValuesInto:(float *)destination capacity:(NSUInteger)capacityBytes
                                   width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error
{
    NSUInteger page = (NSUInteger)getpagesize();
    if (!_volumeTexture || width == 0 || height == 0 || destination == NULL ||
        capacityBytes < width * height * sizeof(float) ||
        ((uintptr_t)destination % page) != 0 || capacityBytes % page != 0 || TARGET_OS_SIMULATOR) {
        // (The iOS Simulator cannot wrap app memory in a Metal buffer: callers use -renderValuesInto: there.)
        if (error) *error = BKRendererError(14, @"Render-ahead needs a volume and page-aligned memory of whole pages (not available in the iOS Simulator).");
        return nil;
    }
    id<MTLBuffer> valueBuffer = [_device newBufferWithBytesNoCopy:destination length:capacityBytes
                                                          options:MTLResourceStorageModeShared deallocator:nil];
    if (_valuesOnlyColorPlaceholder == nil)
        _valuesOnlyColorPlaceholder = [_device newBufferWithLength:16 options:MTLResourceStorageModePrivate];
    if (!valueBuffer || !_valuesOnlyColorPlaceholder) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the output image.");
        return nil;
    }
    // The command buffer keeps valueBuffer (and so the wrapped memory reference) alive while it runs.
    return [self commitRaycastWidth:width height:height colorBuffer:_valuesOnlyColorPlaceholder
                        valueBuffer:valueBuffer valuesOnly:YES error:error];
}

// Exposes the queue for on-screen views (see header).
- (id<MTLCommandQueue>)commandQueue
{
    return _queue;
}

// What: ray-casts the current settings straight into `texture`, without waiting.
// Why: the interactive 3D view renders into the screen's drawable on the GPU; the
// caller commits and presents, so the main thread is never blocked on the GPU.
- (BOOL)encodeRenderToTexture:(id<MTLTexture>)texture
                commandBuffer:(id<MTLCommandBuffer>)commandBuffer
              backgroundColor:(simd_float4)backgroundColor
                        error:(NSError **)error
{
    if (!_volumeTexture) {
        if (error) *error = BKRendererError(13, @"No volume has been set.");
        return NO;
    }
    NSUInteger width = texture.width, height = texture.height;
    if (width == 0 || height == 0) {
        if (error) *error = BKRendererError(14, @"The output image size is zero.");
        return NO;
    }

    BKTransferFunction *tf = [self effectiveTransferFunction];
    [self updateTransferFunctionTexture:tf];

    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return NO;

    id<MTLBuffer> brickEmpty, brickRange;
    [self prepareSkippingForParams:&params commandBuffer:commandBuffer brickEmpty:&brickEmpty brickRange:&brickRange];
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_texturePipeline];
    [enc setTexture:_volumeTexture.texture atIndex:0];
    [enc setTexture:_tfTexture atIndex:1];
    [enc setTexture:texture atIndex:2];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBytes:&backgroundColor length:sizeof(backgroundColor) atIndex:1];
    [enc setBuffer:brickEmpty offset:0 atIndex:2];
    [enc setBuffer:brickRange offset:0 atIndex:3];
    [self bindGeometryToEncoder:enc];   // embedded objects (2026-11-14)
    [self bindBlendToEncoder:enc];      // fused scan (2026-11-24)
    [enc dispatchThreadgroups:MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [enc endEncoding];
    return YES;
}

// What: stretches `source` over `target` with linear filtering (one GPU pass).
// Why: low-resolution frames while interacting must still fill the whole view.
- (void)encodeUpscaleFromTexture:(id<MTLTexture>)source
                       toTexture:(id<MTLTexture>)target
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_upscalePipeline];
    [enc setTexture:source atIndex:0];
    [enc setTexture:target atIndex:1];
    [enc dispatchThreadgroups:MTLSizeMake((target.width + 7) / 8, (target.height + 7) / 8, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [enc endEncoding];
}

- (NSUInteger)gpuParameterBlockSize
{
    id<MTLBuffer> out = [_device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_sizePipeline];
    [enc setBuffer:out offset:0 atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return *(uint32_t *)out.contents;
}

+ (NSUInteger)cpuParameterBlockSize
{
    return sizeof(BKRenderParams);
}

@end
