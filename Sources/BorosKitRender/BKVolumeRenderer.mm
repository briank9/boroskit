// BorosKitRender: BKVolumeRenderer implementation (see the header for what it does).

/* 2026-11-26 (agent "vulkan-engine", Vulkan plan 7.1 #4): the GPU work (tables, brick lists, ray cast) now runs
 * through the backend-neutral BKRaycastPass (shared with the Vulkan engine) and the parameter block comes from the
 * plain-C BKRenderParamsFill; this class keeps its public API, its caches and policy, and the Metal-only upscale.
 */

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
#include "BKRaycastPass.h"   // 2026-11-26: the ray caster on the shared GPU interface (Vulkan plan 7.1 #4b)
#include "BKGPUMetal.h"      // MetalDevice glue
#import "BKGPUEngineBridge.h" // 2026-11-26: the Vulkan TEST engine (Boros 6 MoltenVK switch)
#include <vector>

extern "C" NSString *BKVolumeShaderSource(void); // BKShaderSource.mm

namespace bkgpu = boroskit::gpu;
namespace bkrender = boroskit::render;

// Number of entries in the transfer-function lookup texture. 4096 gives < 1 HU per
// entry over a typical 4000 HU CT range, so the GPU lookup is as fine as the data.
static const NSUInteger kTransferFunctionEntries = BK_TRANSFER_FUNCTION_ENTRIES;

// Makes an NSError in the BorosKitRender domain with a plain-language message.
static NSError *BKRendererError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKRenderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
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
    id<MTLComputePipelineState> _sizePipeline;     // bk_params_size (layout test helper, Metal only)
    id<MTLComputePipelineState> _upscalePipeline;  // bk_upscale (LOD stretch, Metal only)
    id<MTLBuffer> _valuesOnlyColorPlaceholder;     // 16-byte stand-in for the RGBA output when only values are written (2026-11-15)

    // The shared GPU interface on this device + queue, and the ray caster on it (2026-11-26, Vulkan plan 7.1 #4b).
    std::unique_ptr<bkgpu::Device> _gpu;
    std::unique_ptr<bkrender::RaycastPass> _pass;

    // --- Vulkan TEST engine (2026-11-26, BKGPUEngine.h): the same pass on the shared Vulkan device; nullptr = Metal ---
    bkgpu::Device *_vk;
    std::unique_ptr<bkrender::RaycastPass> _vkPass;
    std::unique_ptr<bkgpu::Texture> _vkTable;            // baked transfer function on the Vulkan device
    std::shared_ptr<bkgpu::Buffer> _vkAlphaCount;
    BKTransferFunction *_vkBakedTransferFunction;
    std::unique_ptr<bkgpu::Buffer> _vkBrickRange;        // per volume
    __weak BKVolumeTexture *_vkRangeVolume;
    std::shared_ptr<bkgpu::Buffer> _vkBrickEmpty;
    bkgpu::Buffer *_vkClassifiedAlphaCount;
    __weak BKVolumeTexture *_vkClassifiedVolume;
    std::unique_ptr<bkgpu::Texture> _vkBlendTable;
    BKTransferFunction *_vkBakedBlendTransferFunction;

    std::unique_ptr<bkgpu::Texture> _table;        // baked transfer function (4096 x 1, RGBA float)
    BKTransferFunction *_bakedTransferFunction;    // which function _table currently holds
    BKTransferFunction *_defaultTransferFunction;  // gray ramp used when none is set

    // --- Empty-space skipping (see BK_BRICK_SIZE in BKShaderTypes.h) ---
    std::shared_ptr<bkgpu::Buffer> _alphaCount;    // running count of non-see-through table entries, per bake
    std::shared_ptr<bkgpu::Buffer> _brickEmpty;    // 1 uint32 per brick: 1 = fully see-through
    bkgpu::Buffer *_classifiedAlphaCount;          // which table _brickEmpty was made for
    __weak BKVolumeTexture *_classifiedVolume;     // ...and which volume

    // --- Fusion (2026-11-24, vr-colour-fusion): the fused scan's baked table ---
    id<MTLTexture> _blendTfTexture;              // 4096 x 1 RGBA float, the fused scan's colour / opacity
    BKTransferFunction *_bakedBlendTransferFunction;

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
    _sizePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_params_size"] error:error];
    _upscalePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_upscale"] error:error];
    if (!_sizePipeline || !_upscalePipeline) return nil;
    _queue = [_device newCommandQueue];
    // The ray caster on the shared GPU interface (pipelines, sampler, placeholders).
    if (!_queue || bkgpu::makeMetalDevice(_device, _queue, &_gpu) != bkgpu::Status::Ok ||
        bkgpu::BKGPUMetalAddLibrary(*_gpu, library) != bkgpu::Status::Ok) {
        if (error) *error = BKRendererError(10, @"The GPU interface could not be created.");
        return nil;
    }
    _pass.reset(new bkrender::RaycastPass(*_gpu));
    _vk = bkgpu::BKGPUTestEngineDevice();   // only when the user chose the Vulkan test engine
    if (_vk) {
        std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
        _vkPass.reset(new bkrender::RaycastPass(*_vk));
        if (_vkPass->prepare() != bkgpu::Status::Ok) { _vkPass.reset(); _vk = nullptr; }
    }
    bkgpu::BKGPUEngineLogRenderer("BKVolumeRenderer", _vk != nullptr);
    if (_pass->prepare() != bkgpu::Status::Ok) {
        if (error) *error = BKRendererError(10, @"The ray-casting GPU programs could not be prepared.");
        return nil;
    }
    _blendOpacityUnitDistance = 1;

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

// A NEW table and count list every time (rare: only when the colours / opacity change), so a frame still being
// drawn on the GPU keeps reading the old ones undisturbed. NO when the GPU memory could not be made.
- (BOOL)updateTransferFunctionTexture:(BKTransferFunction *)tf
{
    if (_table && _bakedTransferFunction == tf) return YES;
    float *rgba = (float *)malloc(kTransferFunctionEntries * 4 * sizeof(float));
    [tf bakeIntoRGBA:rgba count:kTransferFunctionEntries];
    std::unique_ptr<bkgpu::Texture> table;
    std::unique_ptr<bkgpu::Buffer> counts;
    bkgpu::Status s = _pass->makeTable(rgba, &table, &counts);   // + the empty-space skipping counts (plain-C core)
    free(rgba);
    if (s != bkgpu::Status::Ok) return NO;
    _table = std::move(table);
    _alphaCount = std::move(counts);
    _bakedTransferFunction = tf;
    return YES;
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
    float *rgba = (float *)malloc(kTransferFunctionEntries * 4 * sizeof(float));
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

// What: the GPU inputs of one ray cast, wrapping the Metal objects (nothing is copied). The wrappers are kept in
// `keep` for the duration of the encoding. Absent objects / fused scan: nullptr (the pass binds its placeholders).
- (bkrender::RaycastInputs)inputsKeeping:(std::vector<std::unique_ptr<bkgpu::Texture>> &)keep
{
    bkrender::RaycastInputs in;
    keep.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, _volumeTexture.texture));
    in.volume = keep.back().get();
    in.table = _table.get();
    if ([self hasGeometry]) {   // embedded objects (2026-11-14)
        keep.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, _geometryColorTexture));
        in.geometryColor = keep.back().get();
        keep.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, _geometryRayDistanceTexture));
        in.geometryDistance = keep.back().get();
    }
    id<MTLTexture> blendTable = [self hasBlend] ? [self bakedBlendTable] : nil;   // fused scan (2026-11-24)
    if (blendTable) {
        keep.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, _blendVolumeTexture.texture));
        in.blendVolume = keep.back().get();
        keep.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, blendTable));
        in.blendTable = keep.back().get();
    }
    return in;
}

#pragma mark - Empty-space skipping

// What: makes sure the volume's per-brick (lowest, highest) list exists; builds it on
// the GPU the first time (RaycastPass) and waits for it.
// Why wait: it is done once per volume (a few milliseconds), and waiting means every
// renderer sharing the volume can use the list at once without any ordering worries.
- (id<MTLBuffer>)brickRangesForVolume:(BKVolumeTexture *)vt
{
    @synchronized (vt) {
        if (vt.brickRangeBuffer) return vt.brickRangeBuffer;
        uint32_t grid[3];
        BKRenderBrickGrid((uint32_t)vt.pixelsWide, (uint32_t)vt.pixelsHigh, (uint32_t)vt.pixelsDeep, BK_BRICK_SIZE, grid);   // plain-C core
        std::unique_ptr<bkgpu::Texture> volume = bkgpu::BKGPUMetalWrapTexture(*_gpu, vt.texture);
        if (!volume) return nil;
        std::unique_ptr<bkgpu::Buffer> ranges = _pass->makeBrickRanges(*volume, grid, nullptr);
        if (!ranges) return nil;
        vt.brickRangeBuffer = bkgpu::BKGPUMetalBuffer(*ranges);   // the MTLBuffer stays alive through the volume
        return vt.brickRangeBuffer;
    }
}

// What: prepares empty-space skipping for one render and tells the shader whether to
// use it (params->skipEmptySpace). In 3D (composite) mode it also re-decides which
// bricks are fully see-through whenever the transfer function or volume changed,
// recorded into `list` ahead of the ray casting. Fills the brick lists of `in` (nullptr = off).
// Why it can never change the picture: see the shader; skipped samples are exactly the
// ones whose contribution would have been thrown away.
- (void)prepareSkippingForParams:(BKRenderParams *)params list:(bkgpu::CommandList &)list
                          inputs:(bkrender::RaycastInputs &)in
                            keep:(std::vector<std::unique_ptr<bkgpu::Buffer>> &)keep
{
    params->skipEmptySpace = 0;
    if (!bkrender::RaycastPass::WantsSkipping(_skipsEmptySpace, *params)) return;   // shared rule
    BKVolumeTexture *vt = _volumeTexture;
    id<MTLBuffer> ranges = [self brickRangesForVolume:vt];
    if (!ranges) return;   // could not build the list: just render without skipping
    uint32_t grid[3];
    BKRenderBrickGrid((uint32_t)vt.pixelsWide, (uint32_t)vt.pixelsHigh, (uint32_t)vt.pixelsDeep, BK_BRICK_SIZE, grid);
    params->brickGrid = bk_make_float4((float)grid[0], (float)grid[1], (float)grid[2], 0.0f);
    keep.push_back(bkgpu::BKGPUMetalWrapBuffer(*_gpu, ranges));
    bkgpu::Buffer *rangeBuffer = keep.back().get();

    if (_mode == BKRenderModeComposite) {
        if (_classifiedAlphaCount != _alphaCount.get() || _classifiedVolume != vt || !_brickEmpty) {
            // A new list each time (rare: only when the colours/opacity change), so a frame still in flight keeps
            // the list it started with.
            std::unique_ptr<bkgpu::Buffer> empty = _pass->encodeClassify(list, *params, *rangeBuffer, *_alphaCount, nullptr);
            if (!empty) return;
            _brickEmpty = std::move(empty);
            _classifiedAlphaCount = _alphaCount.get();
            _classifiedVolume = vt;
        }
        in.brickEmpty = _brickEmpty.get();
    }
    in.brickRange = rangeBuffer;
    params->skipEmptySpace = 1;
}

// What: encodes + runs the CPU-readable ray cast into `colorBuffer` / `valueBuffer` and waits for it.
// `valuesOnly` = the kernel skips the RGBA picture (colorBuffer may then be a tiny placeholder).
// Shared by -renderWithWidth:... and -renderValuesInto:... .
#pragma mark - Vulkan TEST engine (2026-11-26, Boros 6 MoltenVK switch)

// What: the whole ray cast on the Vulkan test device (RaycastPass, same parameter block as Metal), waited for. Inputs
// are copies of the Metal objects (scan / fused scan cached per volume, object pictures every frame); colours (RGBA8
// packed, premultiplied; skipped when valuesOnly) and values land in CPU memory.
- (BOOL)vkRenderWidth:(NSUInteger)width height:(NSUInteger)height valuesOnly:(BOOL)valuesOnly
               colors:(std::vector<uint8_t> *)colors values:(std::vector<float> *)values error:(NSError **)error
{
    std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
    BKTransferFunction *tf = [self effectiveTransferFunction];
    if (!_vkTable || _vkBakedTransferFunction != tf) {
        std::vector<float> rgba(kTransferFunctionEntries * 4);
        [tf bakeIntoRGBA:rgba.data() count:kTransferFunctionEntries];
        std::unique_ptr<bkgpu::Texture> table;
        std::unique_ptr<bkgpu::Buffer> counts;
        if (_vkPass->makeTable(rgba.data(), &table, &counts) != bkgpu::Status::Ok) {
            if (error) *error = BKRendererError(15, @"Not enough memory for the colour table (Vulkan test engine).");
            return NO;
        }
        _vkTable = std::move(table);
        _vkAlphaCount = std::move(counts);
        _vkBakedTransferFunction = tf;
    }
    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return NO;
    params.valuesOnly = valuesOnly ? 1 : 0;

    BKVolumeTexture *vt = _volumeTexture;
    std::shared_ptr<bkgpu::Texture> scan = bkgpu::BKGPUCopyMetalTexture(*_vk, vt.texture, true);
    std::shared_ptr<bkgpu::Texture> geomColor, geomDistance, blendScan;
    bkrender::RaycastInputs in;
    in.volume = scan.get();
    in.table = _vkTable.get();
    if ([self hasGeometry]) {   // these pictures change every frame: fresh copies
        geomColor = bkgpu::BKGPUCopyMetalTexture(*_vk, _geometryColorTexture, false);
        geomDistance = bkgpu::BKGPUCopyMetalTexture(*_vk, _geometryRayDistanceTexture, false);
        in.geometryColor = geomColor.get();
        in.geometryDistance = geomDistance.get();
    }
    if (params.useBlend) {
        BKTransferFunction *btf = _blendTransferFunction;
        if (!_vkBlendTable || _vkBakedBlendTransferFunction != btf) {
            std::vector<float> rgba(kTransferFunctionEntries * 4);
            [btf bakeIntoRGBA:rgba.data() count:kTransferFunctionEntries];
            std::unique_ptr<bkgpu::Texture> table;
            if (_vkPass->makeTable(rgba.data(), &table, nullptr) == bkgpu::Status::Ok) {
                _vkBlendTable = std::move(table);
                _vkBakedBlendTransferFunction = btf;
            }
        }
        blendScan = bkgpu::BKGPUCopyMetalTexture(*_vk, _blendVolumeTexture.texture, true);
        in.blendVolume = blendScan.get();
        in.blendTable = _vkBlendTable.get();
    }
    if (!in.volume || !in.table || (params.useGeometry && (!in.geometryColor || !in.geometryDistance)) ||
        (params.useBlend && (!in.blendVolume || !in.blendTable))) {
        if (error) *error = BKRendererError(16, @"The Vulkan test engine could not copy the scan.");
        return NO;
    }
    std::unique_ptr<bkgpu::CommandList> list = _vk->begin(nullptr);
    if (!list) return NO;
    // Empty-space skipping: the shared rule, the volume's brick list (once per volume), classification per table.
    params.skipEmptySpace = 0;
    if (bkrender::RaycastPass::WantsSkipping(_skipsEmptySpace, params)) {
        uint32_t grid[3];
        BKRenderBrickGrid((uint32_t)vt.pixelsWide, (uint32_t)vt.pixelsHigh, (uint32_t)vt.pixelsDeep, BK_BRICK_SIZE, grid);
        if (!_vkBrickRange || _vkRangeVolume != vt) {
            _vkBrickRange = _vkPass->makeBrickRanges(*scan, grid, nullptr);
            _vkRangeVolume = vt;
            _vkBrickEmpty.reset();
        }
        if (_vkBrickRange) {
            params.brickGrid = bk_make_float4((float)grid[0], (float)grid[1], (float)grid[2], 0.0f);
            bool ok = true;
            if (_mode == BKRenderModeComposite) {
                if (_vkClassifiedAlphaCount != _vkAlphaCount.get() || _vkClassifiedVolume != vt || !_vkBrickEmpty) {
                    std::unique_ptr<bkgpu::Buffer> empty = _vkPass->encodeClassify(*list, params, *_vkBrickRange, *_vkAlphaCount, nullptr);
                    if (empty) {
                        _vkBrickEmpty = std::move(empty);
                        _vkClassifiedAlphaCount = _vkAlphaCount.get();
                        _vkClassifiedVolume = vt;
                    }
                    ok = empty != nullptr || _vkBrickEmpty != nullptr;
                }
                in.brickEmpty = _vkBrickEmpty.get();
            }
            if (ok) {
                in.brickRange = _vkBrickRange.get();
                params.skipEmptySpace = 1;
            }
        }
    }
    uint64_t pixels = (uint64_t)width * height;
    std::unique_ptr<bkgpu::Buffer> colorOut = _vk->makeBuffer(pixels * 4, bkgpu::Memory::Readback, bkgpu::UsageStorage, nullptr);
    std::unique_ptr<bkgpu::Buffer> valueOut = _vk->makeBuffer(pixels * 4, bkgpu::Memory::Readback, bkgpu::UsageStorage, nullptr);
    if (!colorOut || !valueOut || _vkPass->encodeRaycast(*list, params, in, *colorOut, *valueOut) != bkgpu::Status::Ok ||
        _vk->submit(*list, true) != bkgpu::Status::Ok) {
        if (error) *error = BKRendererError(16, @"The Vulkan test engine failed to render the image.");
        return NO;
    }
    if (colors && !valuesOnly) {
        const uint8_t *c = (const uint8_t *)colorOut->map();
        colors->assign(c, c + pixels * 4);
        colorOut->unmap();
    }
    if (values) {
        const float *v = (const float *)valueOut->map();
        values->assign(v, v + pixels);
        valueOut->unmap();
    }
    return YES;
}

- (id<MTLCommandBuffer>)commitRaycastWidth:(NSUInteger)width height:(NSUInteger)height
                               colorBuffer:(id<MTLBuffer>)colorBuffer valueBuffer:(id<MTLBuffer>)valueBuffer
                                valuesOnly:(BOOL)valuesOnly error:(NSError **)error
{
    if (_vk) {   // Vulkan TEST engine: render now (waits), copy into the caller's buffers, hand back a done buffer
        double t0 = bkgpu::BKGPUEngineNowMs();
        std::vector<uint8_t> colors;
        std::vector<float> values;
        if (![self vkRenderWidth:width height:height valuesOnly:valuesOnly colors:&colors values:&values error:error]) return nil;
        if (!valuesOnly && colorBuffer.contents && colorBuffer.length >= colors.size()) memcpy(colorBuffer.contents, colors.data(), colors.size());
        if (valueBuffer.contents) memcpy(valueBuffer.contents, values.data(), values.size() * sizeof(float));
        bkgpu::BKGPUEngineLogFrame(valuesOnly ? "BKVolumeRenderer (values)" : "BKVolumeRenderer", (uint32_t)width, (uint32_t)height,
                                   bkgpu::BKGPUEngineNowMs() - t0);
        return bkgpu::BKGPUFinishedCommandBuffer(_queue);
    }
    BKTransferFunction *tf = [self effectiveTransferFunction];
    if (![self updateTransferFunctionTexture:tf]) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the colour table.");
        return nil;
    }

    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return nil;
    params.valuesOnly = valuesOnly ? 1 : 0;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    {
        // Recorded through the shared interface into this command buffer (the list ends its encoder when it goes).
        std::unique_ptr<bkgpu::CommandList> list = bkgpu::BKGPUMetalCommandList(*_gpu, cb);
        std::vector<std::unique_ptr<bkgpu::Texture>> keepTextures;
        std::vector<std::unique_ptr<bkgpu::Buffer>> keepBuffers;
        bkrender::RaycastInputs in = [self inputsKeeping:keepTextures];
        [self prepareSkippingForParams:&params list:*list inputs:in keep:keepBuffers];
        keepBuffers.push_back(bkgpu::BKGPUMetalWrapBuffer(*_gpu, colorBuffer));
        bkgpu::Buffer *colors = keepBuffers.back().get();
        keepBuffers.push_back(bkgpu::BKGPUMetalWrapBuffer(*_gpu, valueBuffer));
        bkgpu::Buffer *values = keepBuffers.back().get();
        if (!in.volume || _pass->encodeRaycast(*list, params, in, *colors, *values) != bkgpu::Status::Ok) {
            if (error) *error = BKRendererError(16, @"The GPU failed to render the image.");
            return nil;
        }
    }
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

    bkgpu::Format targetFormat;
    if (_vk && bkgpu::BKGPUMetalFormat(texture.pixelFormat, &targetFormat) &&
        (targetFormat == bkgpu::Format::RGBA8Unorm || targetFormat == bkgpu::Format::BGRA8Unorm)) {
        // Vulkan TEST engine: ray cast on Vulkan, then lay the colour over the background exactly like the Metal
        // texture kernel (rgb + (1 - a) * background, opaque) - from the 8-bit packed colour, so up to 1 grey level
        // apart - add the "Vulkan (MoltenVK)" marker and copy it into the drawable within the caller's command buffer.
        double t0 = bkgpu::BKGPUEngineNowMs();
        std::vector<uint8_t> colors;
        if (![self vkRenderWidth:width height:height valuesOnly:NO colors:&colors values:nullptr error:error]) return NO;
        const size_t n = (size_t)width * height;
        for (size_t i = 0; i < n; i++) {
            uint8_t *p = &colors[4 * i];
            float a = p[3] / 255.0f;
            for (int k = 0; k < 3; k++) {
                float v = p[k] / 255.0f + (1.0f - a) * backgroundColor[k];
                p[k] = (uint8_t)(fminf(fmaxf(v, 0.0f), 1.0f) * 255.0f + 0.5f);
            }
            p[3] = 255;
        }
        bool bgra = targetFormat == bkgpu::Format::BGRA8Unorm;
        if (bgra) bkgpu::BKGPUSwapRedBlue(colors.data(), n);
        bkgpu::BKGPUStampTestMarker(colors.data(), (uint32_t)width, (uint32_t)height, bgra);
        if (!bkgpu::BKGPUBlitBytesToMetalTexture(commandBuffer, texture, colors.data(), width * 4)) {
            if (error) *error = BKRendererError(16, @"The Vulkan test picture could not be copied to the screen.");
            return NO;
        }
        bkgpu::BKGPUEngineLogFrame("BKVolumeRenderer (screen)", (uint32_t)width, (uint32_t)height, bkgpu::BKGPUEngineNowMs() - t0);
        return YES;
    }

    BKTransferFunction *tf = [self effectiveTransferFunction];
    if (![self updateTransferFunctionTexture:tf]) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the colour table.");
        return NO;
    }

    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return NO;

    std::unique_ptr<bkgpu::CommandList> list = bkgpu::BKGPUMetalCommandList(*_gpu, commandBuffer);
    std::vector<std::unique_ptr<bkgpu::Texture>> keepTextures;
    std::vector<std::unique_ptr<bkgpu::Buffer>> keepBuffers;
    bkrender::RaycastInputs in = [self inputsKeeping:keepTextures];
    [self prepareSkippingForParams:&params list:*list inputs:in keep:keepBuffers];
    keepTextures.push_back(bkgpu::BKGPUMetalWrapTexture(*_gpu, texture));
    bkgpu::Texture *target = keepTextures.back().get();
    const float background[4] = { backgroundColor.x, backgroundColor.y, backgroundColor.z, backgroundColor.w };
    if (!in.volume || !target || _pass->encodeRaycastToTexture(*list, params, in, *target, background) != bkgpu::Status::Ok) {
        if (error) *error = BKRendererError(16, @"The GPU could not encode the image.");
        return NO;
    }
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
