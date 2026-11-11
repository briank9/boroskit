// BorosKitRender: BKVolumeRenderer implementation (see the header for what it does).

#import "BKVolumeRenderer.h"
#import "BKVolumeTexture.h"
#import "BKTransferFunction.h"
#import "BKShaderTypes.h"
#import "CPRVolumeData.h"

NSString *BKVolumeShaderSource(void); // BKShaderSource.mm

// Number of entries in the transfer-function lookup texture. 4096 gives < 1 HU per
// entry over a typical 4000 HU CT range, so the GPU lookup is as fine as the data.
static const NSUInteger kTransferFunctionEntries = 4096;

// Makes an NSError in the BorosKitRender domain with a plain-language message.
static NSError *BKRendererError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKRenderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Converts an N3Vector (CGFloat, patient mm) to a GPU float3.
static simd_float3 BKFloat3(N3Vector v)
{
    return simd_make_float3((float)v.x, (float)v.y, (float)v.z);
}

#pragma mark - BKRenderResult

@interface BKRenderResult ()
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height rgba:(NSData *)rgba floats:(NSData *)floats;
@end

@implementation BKRenderResult

// Wraps the two output buffers copied back from the GPU.
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
    id<MTLTexture> _tfTexture;            // baked transfer function (4096 x 1, RGBA float)
    BKTransferFunction *_bakedTransferFunction; // which function _tfTexture currently holds
    BKTransferFunction *_defaultTransferFunction; // gray ramp used when none is set
}

// Both accessors are custom (they copy), so the backing variable must be declared explicitly.
@synthesize transferFunction = _transferFunction;

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
            MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
            library = [device newLibraryWithSource:BKVolumeShaderSource() options:options error:error];
            if (library) [cache setObject:library forKey:device];
        }
        return library;
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device ?: MTLCreateSystemDefaultDevice();
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
    if (!_raycastPipeline || !_sizePipeline || !_texturePipeline || !_upscalePipeline) return nil;
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

// Fills the GPU parameter block from the current settings. Builds an orthonormal
// camera frame (right, up, forward) from direction + up so callers may pass any
// non-parallel vectors.
- (BOOL)fillParams:(BKRenderParams *)p width:(NSUInteger)width height:(NSUInteger)height
                tf:(BKTransferFunction *)tf error:(NSError **)error
{
    memset(p, 0, sizeof(*p));
    BKVolumeTexture *vt = _volumeTexture;
    N3AffineTransform m = vt.volumeTransform;

    // patient -> voxel, row-vector convention of N3/CATransform3D:
    // voxel.x = p.x*m11 + p.y*m21 + p.z*m31 + m41 (etc.). As a column-major float3x3
    // that is columns (m11,m12,m13), (m21,m22,m23), (m31,m32,m33).
    p->patientToVoxel = simd_matrix(simd_make_float3(m.m11, m.m12, m.m13),
                                    simd_make_float3(m.m21, m.m22, m.m23),
                                    simd_make_float3(m.m31, m.m32, m.m33));
    p->patientToVoxelTranslation = simd_make_float3(m.m41, m.m42, m.m43);
    p->volumeSize = simd_make_float3(vt.pixelsWide, vt.pixelsHigh, vt.pixelsDeep);

    // Ray-cast region: crop box intersected with the volume's voxel-centre bounds.
    simd_float3 volMax = p->volumeSize - 1.0f;
    p->boxMin = simd_clamp(BKFloat3(_cropMin), simd_make_float3(0, 0, 0), volMax);
    p->boxMax = simd_clamp(BKFloat3(_cropMax), simd_make_float3(0, 0, 0), volMax);

    simd_float3 forward = BKFloat3(_cameraDirection);
    simd_float3 up = BKFloat3(_cameraUp);
    if (simd_length(forward) < 1e-6f) {
        if (error) *error = BKRendererError(11, @"The camera direction is zero.");
        return NO;
    }
    forward = simd_normalize(forward);
    simd_float3 right = simd_cross(forward, up);
    if (simd_length(right) < 1e-6f) {
        if (error) *error = BKRendererError(12, @"The camera up vector is parallel to the viewing direction.");
        return NO;
    }
    right = simd_normalize(right);
    up = simd_cross(right, forward);
    p->cameraPosition = BKFloat3(_cameraPosition);
    p->cameraRight = right;
    p->cameraUp = up;
    p->cameraForward = forward;

    if (_projection == BKProjectionPerspective) {
        float vfov = (float)_fieldOfView * (float)M_PI / 180.0f;
        p->viewHeight = 2.0f * tanf(0.5f * vfov);
        p->viewWidth = p->viewHeight * (float)width / (float)height;
    } else {
        p->viewWidth = (float)_viewWidth;
        p->viewHeight = (float)_viewHeight;
    }

    p->slabPoint = BKFloat3(_slabPlane.point);
    simd_float3 normal = BKFloat3(_slabPlane.normal);
    p->slabNormal = simd_length(normal) > 1e-6f ? simd_normalize(normal) : simd_make_float3(0, 0, 1);
    p->slabThickness = (float)MAX(_slabThickness, 0.0);
    p->useSlab = _slabEnabled ? 1 : 0;

    p->clipPoint = BKFloat3(_clipPlane.point);
    simd_float3 clipNormal = BKFloat3(_clipPlane.normal);
    p->clipNormal = simd_length(clipNormal) > 1e-6f ? simd_normalize(clipNormal) : simd_make_float3(0, 0, 1);
    p->useClip = _clipPlaneEnabled ? 1 : 0;

    p->stepSize = _sampleSpacing > 0 ? (float)_sampleSpacing : (float)(0.5 * vt.minPixelSpacing);
    if (!(p->stepSize > 0)) p->stepSize = 0.5f;
    p->opacityUnitDistance = _opacityUnitDistance > 0 ? _opacityUnitDistance : 1.0f;
    p->valueScale = vt.valueScale;
    p->valueOffset = vt.valueOffset;
    p->tfMin = tf.minimumValue;
    p->tfMax = tf.maximumValue;
    p->windowCenter = _windowCenter;
    p->windowWidth = _windowWidth;
    // missValue (if set) overrides the volume's outside value, e.g. to match VTK's.
    p->outOfBoundsValue = isnan(_missValue) ? vt.outOfBoundsValue : _missValue;
    p->ambient = _ambient;
    p->diffuse = _diffuse;
    p->specular = _specular;
    p->specularPower = _specularPower;
    p->width = (uint32_t)width;
    p->height = (uint32_t)height;
    p->mode = _mode;
    p->projection = _projection;
    p->shading = _shadingEnabled ? 1 : 0;
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

    BKTransferFunction *tf = [self effectiveTransferFunction];
    [self updateTransferFunctionTexture:tf];

    BKRenderParams params;
    if (![self fillParams:&params width:width height:height tf:tf error:error]) return nil;

    NSUInteger pixels = width * height;
    id<MTLBuffer> colorBuffer = [_device newBufferWithLength:pixels * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> valueBuffer = [_device newBufferWithLength:pixels * sizeof(float) options:MTLResourceStorageModeShared];
    if (!colorBuffer || !valueBuffer) {
        if (error) *error = BKRendererError(15, @"Not enough memory for the output image.");
        return nil;
    }

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_raycastPipeline];
    [enc setTexture:_volumeTexture.texture atIndex:0];
    [enc setTexture:_tfTexture atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBuffer:colorBuffer offset:0 atIndex:1];
    [enc setBuffer:valueBuffer offset:0 atIndex:2];
    // 8x8 tiles: neighbouring rays read neighbouring voxels, which keeps the texture
    // cache warm. Thread groups are dispatched to cover the image; the kernel skips
    // threads that fall outside it.
    MTLSize group = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [enc dispatchThreadgroups:groups threadsPerThreadgroup:group];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) {
        if (error) *error = cb.error ?: BKRendererError(16, @"The GPU failed to render the image.");
        return nil;
    }

    return [[BKRenderResult alloc] initWithWidth:width height:height
                                            rgba:[NSData dataWithBytes:colorBuffer.contents length:pixels * 4]
                                          floats:[NSData dataWithBytes:valueBuffer.contents length:pixels * sizeof(float)]];
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

    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_texturePipeline];
    [enc setTexture:_volumeTexture.texture atIndex:0];
    [enc setTexture:_tfTexture atIndex:1];
    [enc setTexture:texture atIndex:2];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBytes:&backgroundColor length:sizeof(backgroundColor) atIndex:1];
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
