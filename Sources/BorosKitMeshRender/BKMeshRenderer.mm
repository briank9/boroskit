// BorosKitMeshRender: BKMeshObject / BKMeshRenderer implementation (see the header).

/* BOROS OVERVIEW (plain language)
 * This is the engine that draws 3D surfaces (bone models, scans, implants) on the
 * graphics chip. For every picture it:
 *   1. copies each mesh to the graphics chip's memory, only when it has changed;
 *   2. works out the camera from the same settings the 3D volume picture uses, so
 *      both line up exactly;
 *   3. draws the solid objects first, keeping for each pixel only the surface nearest
 *      to the viewer ("depth test"), then the see-through ones from back to front;
 *   4. for tests and exports, copies the finished picture back from the graphics chip.
 */

#import "BKMeshRenderer.h"
#import "BKMeshShaderTypes.h"
#import "BKVolumeTexture.h"   // BKRenderErrorDomain
#import "BKMeshDrawCore.h"    // 2026-11-14: culling / texture / point rules (plain C)
#import "BKMetalDevice.h"     // the user's chosen graphics card (Automatic by default)
// 2026-11-26 (Vulkan plan phase 2): the drawing itself is BKMeshPass (backend-neutral C++) on the shared GPU interface;
// this class is the Metal glue (object caches, Metal targets / command buffers wrapped for the pass).
#import "BKGPUMetal.h"
#include "BKMeshPass.h"
#import "BKGPUEngineBridge.h"   // 2026-11-26: the Vulkan TEST engine (Boros 6 MoltenVK switch)
#include <memory>
#include <vector>

extern "C" NSString *BKMeshShaderSource(void); // BKMeshShaderSource.mm

// BKRenderResult's initializer is private to BorosKitRender; declaring it here lets
// the mesh renderer return the same result type as the volume renderer (same pixel
// helpers, same CGImage export) without changing BorosKitRender.
@interface BKRenderResult (BKMeshRendererAccess)
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height rgba:(NSData *)rgba floats:(NSData *)floats;
@end

// Makes an NSError in the render domain with a plain-language message.
static NSError *BKMeshRenderError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKRenderErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// N3Vector (CGFloat) -> GPU float3.
static simd_float3 BKMeshFloat3(N3Vector v)
{
    return simd_make_float3((float)v.x, (float)v.y, (float)v.z);
}

#pragma mark - BKMeshTexture (2026-11-14)

// Renderer-only part of BKMeshTexture: its GPU copy.
@interface BKMeshTexture ()
- (nullable id<MTLTexture>)textureOnDevice:(id<MTLDevice>)device;
@end

@implementation BKMeshTexture {
    id<MTLTexture> _gpuTexture;            // GPU copy (made on first use)
    __weak id<MTLDevice> _gpuDevice;
}

// What: converts the pixels to RGBA8 (BKMeshTextureExpandToRGBA8: the OpenGL / VTK meaning of
// 1-4 components) and notes whether any texel is see-through.
- (instancetype)initWithPixels:(const uint8_t *)pixels components:(NSUInteger)components
                         width:(NSUInteger)width height:(NSUInteger)height
{
    if (pixels == NULL || width == 0 || height == 0 || components < 1 || components > 4) return nil;
    if (!(self = [super init])) return nil;
    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    if (!rgba || !BKMeshTextureExpandToRGBA8(pixels, (uint32_t)components, width * height, (uint8_t *)rgba.mutableBytes)) return nil;
    const uint8_t *p = (const uint8_t *)rgba.bytes;   // explicit cast: this file is Objective-C++ since 2026-11-26
    BOOL opaque = YES;
    for (NSUInteger i = 0; i < width * height && opaque; i++) opaque = (p[4 * i + 3] == 255);
    _width = width;
    _height = height;
    _rgba8Data = rgba;
    _opaque = opaque;
    _interpolate = YES;
    _repeat = YES;
    return self;
}

// What: the GPU copy of the picture (uploaded once per GPU). Row 0 of the data becomes row 0
// of the Metal texture, which Metal samples at t = 0 - the same rule as OpenGL / VTK.
- (id<MTLTexture>)textureOnDevice:(id<MTLDevice>)device
{
    if (_gpuTexture && _gpuDevice == device) return _gpuTexture;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:_width height:_height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    if (!texture) return nil;
    [texture replaceRegion:MTLRegionMake2D(0, 0, _width, _height) mipmapLevel:0 withBytes:_rgba8Data.bytes bytesPerRow:_width * 4];
    _gpuTexture = texture;
    _gpuDevice = device;
    return texture;
}

@end

#pragma mark - BKMeshObject

// Renderer-only part of BKMeshObject: the GPU copy of its mesh.
@interface BKMeshObject ()
- (BOOL)prepareBuffersOnDevice:(id<MTLDevice>)device;
- (id<MTLBuffer>)vertexBuffer;
- (id<MTLBuffer>)indexBuffer;
- (nullable id<MTLBuffer>)textureCoordinateBufferOnDevice:(id<MTLDevice>)device;   // 2026-11-14
@end

@implementation BKMeshObject {
    // GPU copy of the mesh (owned by whichever renderer uploaded it).
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _indexBuffer;
    __weak BKMesh *_uploadedMesh;     // which mesh / version / GPU the buffers hold
    NSUInteger _uploadedVersion;
    __weak id<MTLDevice> _uploadedDevice;
    // 2026-11-14: texture coordinates and their GPU copy.
    NSData *_textureCoordinateData;    // textureCoordinateCount simd_float2
    id<MTLBuffer> _textureCoordinateBuffer;
    __weak id<MTLDevice> _textureCoordinateDevice;
}

- (instancetype)initWithMesh:(BKMesh *)mesh
{
    if ((self = [super init])) {
        _mesh = mesh;
        _color = simd_make_float3(0.95f, 0.92f, 0.84f);   // light bone colour
        _opacity = 1;
        _visible = YES;
        _useVertexColors = YES;
        _transform = matrix_identity_float4x4;
        // Own lighting (only used when usesOwnMaterial is YES): the renderer's defaults.
        _ambient = 0.2f;
        _diffuse = 0.8f;
        _specular = 0.2f;
        _specularPower = 10;
        _lit = YES;
    }
    return self;
}

- (instancetype)init
{
    return [self initWithMesh:[[BKMesh alloc] init]];
}

// What: the 8 corners of the mesh's box, moved by `transform`, then their min/max.
// Why: the renderer needs to know how deep the scene is to set the depth range.
- (void)getPatientBoundsMin:(simd_float3 *)outMin max:(simd_float3 *)outMax
{
    simd_float3 lo = _mesh.boundsMin, hi = _mesh.boundsMax;
    simd_float3 mn = simd_make_float3(INFINITY, INFINITY, INFINITY), mx = -mn;
    for (int i = 0; i < 8; i++) {
        simd_float4 c = simd_make_float4((i & 1) ? hi.x : lo.x, (i & 2) ? hi.y : lo.y, (i & 4) ? hi.z : lo.z, 1);
        simd_float4 p = simd_mul(_transform, c);
        if (p.w != 0 && p.w != 1) p /= p.w;
        mn = simd_min(mn, p.xyz);
        mx = simd_max(mx, p.xyz);
    }
    if (outMin) *outMin = mn;
    if (outMax) *outMax = mx;
}

// What: makes sure the GPU holds the current version of the mesh; uploads if not.
// Why: uploading a million-triangle scan every frame would be far too slow, but a
// changed mesh must never be drawn from a stale copy.
- (BOOL)prepareBuffersOnDevice:(id<MTLDevice>)device
{
    BKMesh *mesh = _mesh;
    if (!mesh || mesh.triangleCount == 0) return NO;
    if (_vertexBuffer && _uploadedMesh == mesh && _uploadedVersion == mesh.version && _uploadedDevice == device) return YES;

    NSUInteger n = mesh.vertexCount;
    id<MTLBuffer> vb = [device newBufferWithLength:MAX(n, (NSUInteger)1) * sizeof(BKMeshGPUVertex) options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [device newBufferWithBytes:mesh.indices length:mesh.triangleCount * 3 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!vb || !ib) return NO;
    BKMeshGPUVertex *out = (BKMeshGPUVertex *)vb.contents;
    const simd_float3 *p = mesh.vertices, *nrm = mesh.normals;
    const simd_float4 *col = mesh.colors;
    for (NSUInteger i = 0; i < n; i++) {
        out[i].position[0] = p[i].x; out[i].position[1] = p[i].y; out[i].position[2] = p[i].z;
        simd_float3 nv = nrm ? nrm[i] : simd_make_float3(0, 0, 0);
        out[i].normal[0] = nv.x; out[i].normal[1] = nv.y; out[i].normal[2] = nv.z;
        simd_float4 c = col ? col[i] : simd_make_float4(1, 1, 1, 1);
        out[i].color[0] = c.x; out[i].color[1] = c.y; out[i].color[2] = c.z; out[i].color[3] = c.w;
    }
    _vertexBuffer = vb;
    _indexBuffer = ib;
    _uploadedMesh = mesh;
    _uploadedVersion = mesh.version;
    _uploadedDevice = device;
    return YES;
}

- (id<MTLBuffer>)vertexBuffer { return _vertexBuffer; }
- (id<MTLBuffer>)indexBuffer { return _indexBuffer; }

// What (2026-11-14): copies the texture coordinates (NULL / 0 removes them) and forgets the
// old GPU copy.
- (void)setTextureCoordinates:(const simd_float2 *)coordinates count:(NSUInteger)count
{
    _textureCoordinateData = (coordinates && count) ? [NSData dataWithBytes:coordinates length:count * sizeof(simd_float2)] : nil;
    _textureCoordinateCount = _textureCoordinateData ? count : 0;
    _textureCoordinateBuffer = nil;
}

- (const simd_float2 *)textureCoordinates
{
    return (const simd_float2 *)_textureCoordinateData.bytes;
}

// What: drawn with a texture only when there is one AND one coordinate per vertex.
// Why: VTK draws a textured actor without texture coordinates as if it had no texture.
- (BOOL)isTextured
{
    return _texture != nil && _textureCoordinateCount > 0 && _textureCoordinateCount == _mesh.vertexCount;
}

// What: the GPU copy of the texture coordinates, tightly packed float x2 (8-byte stride).
- (id<MTLBuffer>)textureCoordinateBufferOnDevice:(id<MTLDevice>)device
{
    if (_textureCoordinateCount == 0) return nil;
    if (_textureCoordinateBuffer && _textureCoordinateDevice == device) return _textureCoordinateBuffer;
    id<MTLBuffer> buffer = [device newBufferWithLength:_textureCoordinateCount * 2 * sizeof(float) options:MTLResourceStorageModeShared];
    if (!buffer) return nil;
    float *out = (float *)buffer.contents;
    const simd_float2 *tc = self.textureCoordinates;
    for (NSUInteger i = 0; i < _textureCoordinateCount; i++) { out[2 * i] = tc[i].x; out[2 * i + 1] = tc[i].y; }
    _textureCoordinateBuffer = buffer;
    _textureCoordinateDevice = device;
    return buffer;
}

@end

#pragma mark - BKLineObject

// Renderer-only part of BKLineObject: the GPU copy of its points.
@interface BKLineObject ()
- (BOOL)prepareBufferOnDevice:(id<MTLDevice>)device;
- (id<MTLBuffer>)pointBuffer;
@end

@implementation BKLineObject {
    NSData *_pointData;                // 2 * segmentCount simd_float3
    NSUInteger _version;               // goes up when the points change
    id<MTLBuffer> _buffer;             // GPU copy (packed float3, 12 bytes per point)
    NSUInteger _uploadedVersion;
    __weak id<MTLDevice> _uploadedDevice;
}

- (instancetype)initWithPoints:(const simd_float3 *)points count:(NSUInteger)count
{
    if ((self = [super init])) {
        _color = simd_make_float3(1, 1, 1);
        _opacity = 1;
        _lineWidth = 1;
        _visible = YES;
        _transform = matrix_identity_float4x4;
        [self setPoints:points count:count];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithPoints:NULL count:0];
}

// What: copies the segment end points (an odd last point is dropped).
- (void)setPoints:(const simd_float3 *)points count:(NSUInteger)count
{
    NSUInteger even = (points ? count : 0) & ~(NSUInteger)1;
    _pointData = [NSData dataWithBytes:points length:even * sizeof(simd_float3)];
    _segmentCount = even / 2;
    _version++;
}

- (const simd_float3 *)points
{
    return (const simd_float3 *)_pointData.bytes;
}

// What: box around all end points, pushed through `transform`.
- (void)getPatientBoundsMin:(simd_float3 *)outMin max:(simd_float3 *)outMax
{
    simd_float3 mn = simd_make_float3(INFINITY, INFINITY, INFINITY), mx = -mn;
    const simd_float3 *p = self.points;
    for (NSUInteger i = 0; i < 2 * _segmentCount; i++) {
        simd_float4 q = simd_mul(_transform, simd_make_float4(p[i], 1));
        if (q.w != 0 && q.w != 1) q /= q.w;
        mn = simd_min(mn, q.xyz);
        mx = simd_max(mx, q.xyz);
    }
    if (outMin) *outMin = mn;
    if (outMax) *outMax = mx;
}

// What: makes sure the GPU holds the current points (packed, 3 floats each).
// Why: same as meshes: upload only when something changed.
- (BOOL)prepareBufferOnDevice:(id<MTLDevice>)device
{
    if (_segmentCount == 0) return NO;
    if (_buffer && _uploadedVersion == _version && _uploadedDevice == device) return YES;
    NSUInteger n = 2 * _segmentCount;
    id<MTLBuffer> buffer = [device newBufferWithLength:n * 3 * sizeof(float) options:MTLResourceStorageModeShared];
    if (!buffer) return NO;
    float *out = (float *)buffer.contents;
    const simd_float3 *p = self.points;
    for (NSUInteger i = 0; i < n; i++) {
        out[3 * i] = p[i].x; out[3 * i + 1] = p[i].y; out[3 * i + 2] = p[i].z;
    }
    _buffer = buffer;
    _uploadedVersion = _version;
    _uploadedDevice = device;
    return YES;
}

- (id<MTLBuffer>)pointBuffer { return _buffer; }

@end

#pragma mark - BKPointObject (2026-11-14)

// Renderer-only part of BKPointObject: the GPU copy of its points.
@interface BKPointObject ()
- (BOOL)prepareBufferOnDevice:(id<MTLDevice>)device;
- (id<MTLBuffer>)pointBuffer;
@end

@implementation BKPointObject {
    NSData *_pointData;                // pointCount simd_float3
    NSUInteger _version;               // goes up when the points change
    id<MTLBuffer> _buffer;             // GPU copy (packed float3, 12 bytes per point)
    NSUInteger _uploadedVersion;
    __weak id<MTLDevice> _uploadedDevice;
}

- (instancetype)initWithPoints:(const simd_float3 *)points count:(NSUInteger)count
{
    if ((self = [super init])) {
        _color = simd_make_float3(1, 1, 1);
        _opacity = 1;
        _pointSize = 1;
        _visible = YES;
        _transform = matrix_identity_float4x4;
        [self setPoints:points count:count];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithPoints:NULL count:0];
}

// What: copies the positions.
- (void)setPoints:(const simd_float3 *)points count:(NSUInteger)count
{
    NSUInteger n = points ? count : 0;
    _pointData = [NSData dataWithBytes:points length:n * sizeof(simd_float3)];
    _pointCount = n;
    _version++;
}

- (const simd_float3 *)points
{
    return (const simd_float3 *)_pointData.bytes;
}

// What: box around all points, pushed through `transform`.
- (void)getPatientBoundsMin:(simd_float3 *)outMin max:(simd_float3 *)outMax
{
    simd_float3 mn = simd_make_float3(INFINITY, INFINITY, INFINITY), mx = -mn;
    const simd_float3 *p = self.points;
    for (NSUInteger i = 0; i < _pointCount; i++) {
        simd_float4 q = simd_mul(_transform, simd_make_float4(p[i], 1));
        if (q.w != 0 && q.w != 1) q /= q.w;
        mn = simd_min(mn, q.xyz);
        mx = simd_max(mx, q.xyz);
    }
    if (outMin) *outMin = mn;
    if (outMax) *outMax = mx;
}

// What: makes sure the GPU holds the current points (packed, 3 floats each), like lines.
- (BOOL)prepareBufferOnDevice:(id<MTLDevice>)device
{
    if (_pointCount == 0) return NO;
    if (_buffer && _uploadedVersion == _version && _uploadedDevice == device) return YES;
    id<MTLBuffer> buffer = [device newBufferWithLength:_pointCount * 3 * sizeof(float) options:MTLResourceStorageModeShared];
    if (!buffer) return NO;
    float *out = (float *)buffer.contents;
    const simd_float3 *p = self.points;
    for (NSUInteger i = 0; i < _pointCount; i++) {
        out[3 * i] = p[i].x; out[3 * i + 1] = p[i].y; out[3 * i + 2] = p[i].z;
    }
    _buffer = buffer;
    _uploadedVersion = _version;
    _uploadedDevice = device;
    return YES;
}

- (id<MTLBuffer>)pointBuffer { return _buffer; }

@end

#pragma mark - BKMeshRenderer

// What the draw loop needs per visible object.
@interface BKMeshDrawItem : NSObject
@property (nonatomic, strong) BKMeshObject *object;      // a mesh, or
@property (nonatomic, strong) BKLineObject *lineObject;  // a set of lines, or
@property (nonatomic, strong) BKPointObject *pointObject; // a set of points (2026-11-14)
@property (nonatomic) float sortDistance;   // along the view direction, for back-to-front order
@end
@implementation BKMeshDrawItem
@end

@implementation BKMeshRenderer {
    id<MTLLibrary> _library;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _sizePipeline;
    // 2026-11-26 (phase 2): the shared GPU interface on this Metal device, and the backend-neutral mesh pass that
    // owns the pipelines, depth buffer and samplers (formerly ivars of this class).
    std::unique_ptr<boroskit::gpu::Device> _gpu;
    std::unique_ptr<boroskit::meshpass::MeshPass> _pass;
    // 2026-11-26: the same pass on the Vulkan TEST engine (BKGPUEngine.h); nullptr = Metal (default).
    boroskit::gpu::Device *_vk;
    std::unique_ptr<boroskit::meshpass::MeshPass> _vkPass;
}

// Compiles the shader library once per GPU and shares it between renderers (compiling
// is the slow part of creating a renderer).
+ (id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device error:(NSError **)error
{
    static NSMapTable<id<MTLDevice>, id<MTLLibrary>> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized (cache) {
        id<MTLLibrary> library = [cache objectForKey:device];
        if (!library) {
            library = [device newLibraryWithSource:BKMeshShaderSource() options:[BKMetalDevice shaderCompileOptions] /* fast math off, 2026-11-14 */ error:error];
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
        if (error) *error = BKMeshRenderError(30, @"No Metal GPU is available on this device.");
        return nil;
    }
    _library = [[self class] libraryForDevice:_device error:error];
    if (!_library) return nil;
    _sizePipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"bk_mesh_uniforms_size"] error:error];
    if (!_sizePipeline) return nil;
    _queue = [_device newCommandQueue];
    // 2026-11-26 (phase 2): MetalDevice + MeshPass. The pass makes the four texture samplers (2026-11-14 rules).
    if (boroskit::gpu::makeMetalDevice(_device, &_gpu) != boroskit::gpu::Status::Ok ||
        boroskit::gpu::BKGPUMetalAddLibrary(*_gpu, _library) != boroskit::gpu::Status::Ok) {
        if (error) *error = BKMeshRenderError(30, @"No Metal GPU is available on this device.");
        return nil;
    }
    _pass.reset(new boroskit::meshpass::MeshPass(*_gpu));
    if (!_pass->valid()) {
        if (error) *error = BKMeshRenderError(40, @"The GPU could not create a texture sampler.");
        return nil;
    }
    _vk = boroskit::gpu::BKGPUTestEngineDevice();   // only when the user chose the Vulkan test engine
    if (_vk) {
        std::lock_guard<std::recursive_mutex> lock(boroskit::gpu::BKGPUTestEngineMutex());
        _vkPass.reset(new boroskit::meshpass::MeshPass(*_vk));
        if (!_vkPass->valid()) { _vkPass.reset(); _vk = nullptr; }
    }
    boroskit::gpu::BKGPUEngineLogRenderer("BKMeshRenderer", _vk != nullptr);
    _objects = @[];
    _lineObjects = @[];
    _pointObjects = @[];
    _viewport = CGRectZero;
    // Defaults: the same as BKVolumeRenderer (front view, head up, 100 mm, its lighting).
    _projection = BKProjectionOrthographic;
    _cameraPosition = N3VectorZero;
    _cameraDirection = N3VectorMake(0, 1, 0);
    _cameraUp = N3VectorMake(0, 0, 1);
    _viewWidth = _viewHeight = 100;
    _fieldOfView = 30;
    _ambient = 0.2f;
    _diffuse = 0.8f;
    _specular = 0.2f;
    _specularPower = 10;
    return self;
}

- (id<MTLCommandQueue>)commandQueue
{
    return _queue;
}

#pragma mark Camera

// What: the same conversion as -[BKVolumeCamera applyToRenderer:aspectRatio:].
// Why: one interactive camera must drive the volume and the meshes identically.
- (void)setCameraFromVolumeCamera:(BKVolumeCamera *)camera aspectRatio:(CGFloat)aspectRatio
{
    if (!(aspectRatio > 0)) aspectRatio = 1;
    _projection = camera.projection;
    _cameraDirection = camera.direction;
    _cameraUp = camera.viewUp;
    if (camera.projection == BKProjectionPerspective) {
        _cameraPosition = camera.position;
        _fieldOfView = camera.viewAngle;
    } else {
        _cameraPosition = camera.focalPoint;
        _viewHeight = 2.0 * camera.parallelScale;
        _viewWidth = 2.0 * camera.parallelScale * aspectRatio;
    }
}

- (void)copyCameraFromVolumeRenderer:(BKVolumeRenderer *)r
{
    _projection = r.projection;
    _cameraPosition = r.cameraPosition;
    _cameraDirection = r.cameraDirection;
    _cameraUp = r.cameraUp;
    _viewWidth = r.viewWidth;
    _viewHeight = r.viewHeight;
    _fieldOfView = r.fieldOfView;
}

// What (2026-11-25, vulkan-engine M3): this renderer's camera as the plain-C BKMeshCamera, the input of
// the shared uniform builder in BKMeshDrawCore (the same functions a Vulkan mesh pass calls).
- (BKMeshCamera)meshCamera
{
    BKMeshCamera c;
    c.projection = _projection;
    c.position = BKV3d(_cameraPosition.x, _cameraPosition.y, _cameraPosition.z);
    c.direction = BKV3d(_cameraDirection.x, _cameraDirection.y, _cameraDirection.z);
    c.up = BKV3d(_cameraUp.x, _cameraUp.y, _cameraUp.z);
    c.viewWidth = _viewWidth;
    c.viewHeight = _viewHeight;
    c.fieldOfView = _fieldOfView;
    return c;
}

// What: turns a BKMeshCamera* status into this renderer's error (same codes and messages as before).
static BOOL BKMeshCameraStatusOK(int32_t status, NSError **error)
{
    switch (status) {
        case BKMeshCameraOK: return YES;
        case BKMeshCameraZeroDirection:
            if (error) *error = BKMeshRenderError(31, @"The camera direction is zero.");
            return NO;
        case BKMeshCameraUpParallel:
            if (error) *error = BKMeshRenderError(32, @"The camera up vector is parallel to the viewing direction.");
            return NO;
        default:
            if (error) *error = BKMeshRenderError(36, @"The camera's field of view is zero.");
            return NO;
    }
}

// What: the orthonormal camera frame (right, up, forward) as GPU floats. Returns NO + error for a zero
// or degenerate camera. 2026-11-25 (M3): built by BKMeshCameraAxes (plain C, double, via BKCameraMath)
// instead of Apple simd in float here, so Metal and a Vulkan backend use one definition.
- (BOOL)getCameraRight:(simd_float3 *)right up:(simd_float3 *)up forward:(simd_float3 *)forward error:(NSError **)error
{
    BKMeshCamera camera = [self meshCamera];
    BKVec3d r, u, f;
    if (!BKMeshCameraStatusOK(BKMeshCameraAxes(&camera, &r, &u, &f), error)) return NO;
    *right = simd_make_float3((float)r.x, (float)r.y, (float)r.z);
    *up = simd_make_float3((float)u.x, (float)u.y, (float)u.z);
    *forward = simd_make_float3((float)f.x, (float)f.y, (float)f.z);
    return YES;
}

// 2026-11-26 (phase 2): pipelines, depth states, the depth buffer and samplers now live in BKMeshPass (shared by
// the Metal and Vulkan engines); see BKMeshPass.cpp for the same settings as before.

#pragma mark Drawing

- (BOOL)encodeRenderToColorTexture:(id<MTLTexture>)colorTexture
                rayDistanceTexture:(id<MTLTexture>)distanceTexture
                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                             clear:(BOOL)clear
                        clearColor:(simd_float4)clearColor
                             error:(NSError **)error
{
    NSUInteger width = colorTexture.width, height = colorTexture.height;
    if (width == 0 || height == 0) {
        if (error) *error = BKMeshRenderError(33, @"The output image size is zero.");
        return NO;
    }
    if (distanceTexture && (distanceTexture.width != width || distanceTexture.height != height ||
                            distanceTexture.pixelFormat != MTLPixelFormatR32Float)) {
        if (error) *error = BKMeshRenderError(34, @"The ray-distance texture must be R32Float and the same size as the colour texture.");
        return NO;
    }
    // Drawing area: the viewport (clipped to the image), or the whole image.
    CGRect area = CGRectMake(0, 0, width, height);
    if (!CGRectIsEmpty(_viewport)) area = CGRectIntersection(CGRectIntegral(_viewport), area);
    if (CGRectIsEmpty(area)) {
        if (error) *error = BKMeshRenderError(39, @"The viewport lies outside the output image.");
        return NO;
    }
    simd_float3 right, up, forward;
    if (![self getCameraRight:&right up:&up forward:&forward error:error]) return NO;

    // 2026-11-26 (Vulkan plan phase 2): this method is now Metal glue around BKMeshPass (backend-neutral C++, the same
    // code a Vulkan engine runs). Here: pick the visible, uploaded objects (as before) and describe them to the pass,
    // wrapping the Metal buffers / textures each object already caches - nothing is copied.
    using namespace boroskit;
    // 2026-11-26: Vulkan TEST engine (BKGPUEngine.h): the same items on copies of the objects' buffers / textures, drawn
    // on the Vulkan device, read back and copied into the caller's textures. Only a fresh picture (clear) - drawing over
    // what earlier commands of this command buffer put there stays on Metal (they have not run yet).
    gpu::Format vkFormat = gpu::Format::RGBA8Unorm;
    const bool vk = _vk && clear && gpu::BKGPUMetalFormat(colorTexture.pixelFormat, &vkFormat) &&
                    (vkFormat == gpu::Format::RGBA8Unorm || vkFormat == gpu::Format::BGRA8Unorm);
    std::unique_lock<std::recursive_mutex> vkLock;
    if (vk) vkLock = std::unique_lock<std::recursive_mutex>(gpu::BKGPUTestEngineMutex());
    else if (_vk) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ NSLog(@"Boros GPU engine: BKMeshRenderer draws over an existing picture (or into a non-8-bit target) with Metal even in Vulkan test mode"); });
    }
    std::vector<std::shared_ptr<gpu::Buffer>> vkBuffers;    // copies on the Vulkan device (cached per Metal buffer)
    std::vector<std::shared_ptr<gpu::Texture>> vkTextures;
    std::vector<meshpass::Item> items;
    std::vector<std::unique_ptr<gpu::Buffer>> buffers;     // wrappers, alive until the pass is recorded
    std::vector<std::unique_ptr<gpu::Texture>> textures;
    auto wrap = [&](id<MTLBuffer> b) -> gpu::Buffer * {
        if (!b) return nullptr;
        if (vk) {
            vkBuffers.push_back(gpu::BKGPUCopyMetalBuffer(*_vk, b));
            return vkBuffers.back().get();
        }
        buffers.push_back(gpu::BKGPUMetalWrapBuffer(*_gpu, b));
        return buffers.back().get();
    };
    auto bounds = [](meshpass::Item &it, simd_float3 lo, simd_float3 hi) {
        it.boundsMin = BKV3f(lo.x, lo.y, lo.z);
        it.boundsMax = BKV3f(hi.x, hi.y, hi.z);
    };
    for (BKMeshObject *object in _objects) {
        if (!object.visible || !(object.opacity > 0)) continue;
        if (![object prepareBuffersOnDevice:_device]) continue;
        BKMesh *mesh = object.mesh;
        meshpass::Item it;
        it.kind = meshpass::ItemKind::Mesh;
        simd_float3 lo, hi;
        [object getPatientBoundsMin:&lo max:&hi];
        bounds(it, lo, hi);
        it.vertices = wrap([object vertexBuffer]);
        it.indices = wrap([object indexBuffer]);
        it.indexCount = (uint32_t)(mesh.triangleCount * 3);
        if (object.textured) {   // 2026-11-14: texture + coordinates, when both are on the GPU
            BKMeshTexture *texture = object.texture;
            id<MTLTexture> gpuTexture = [texture textureOnDevice:_device];
            id<MTLBuffer> tcBuffer = [object textureCoordinateBufferOnDevice:_device];
            if (gpuTexture && tcBuffer) {
                if (vk) {
                    vkTextures.push_back(gpu::BKGPUCopyMetalTexture(*_vk, gpuTexture, true));
                    it.texture = vkTextures.back().get();
                } else {
                    textures.push_back(gpu::BKGPUMetalWrapTexture(*_gpu, gpuTexture));
                    it.texture = textures.back().get();
                }
                it.textureCoordinates = it.texture ? wrap(tcBuffer) : nullptr;
                it.samplerIndex = (texture.interpolate ? 2 : 0) + (texture.repeat ? 1 : 0);
            }
        }
        simd_float4x4 placement = object.transform;
        memcpy(it.model, &placement, sizeof it.model);
        it.color[0] = object.color.x; it.color[1] = object.color.y; it.color[2] = object.color.z;
        it.opacity = object.opacity;
        it.useVertexColors = (object.useVertexColors && mesh.colors) ? 1 : 0;
        it.hasNormals = mesh.normals ? 1 : 0;
        it.lit = object.lit ? 1 : 0;
        it.ownMaterial = object.usesOwnMaterial ? 1 : 0;
        it.material = (BKMeshLighting){ object.ambient, object.diffuse, object.specular, object.specularPower };
        it.cull = object.faceCulling == BKMeshFaceCullingBack ? gpu::CullMode::Back
                : object.faceCulling == BKMeshFaceCullingFront ? gpu::CullMode::Front : gpu::CullMode::None;
        it.wireframe = object.wireframe ? 1 : 0;
        // 2026-11-14: a texture with see-through texels makes the object see-through (as in VTK).
        it.solid = (object.opacity >= 1 && !(object.textured && !object.texture.opaque)) ? 1 : 0;
        items.push_back(it);
    }
    for (BKLineObject *lines in _lineObjects) {
        if (!lines.visible || !(lines.opacity > 0) || !(lines.lineWidth > 0)) continue;
        if (![lines prepareBufferOnDevice:_device]) continue;
        meshpass::Item it;
        it.kind = meshpass::ItemKind::Lines;
        simd_float3 lo, hi;
        [lines getPatientBoundsMin:&lo max:&hi];
        bounds(it, lo, hi);
        it.vertices = wrap([lines pointBuffer]);
        it.vertexCount = (uint32_t)(lines.segmentCount * 6);
        simd_float4x4 placement = lines.transform;
        memcpy(it.model, &placement, sizeof it.model);
        it.color[0] = lines.color.x; it.color[1] = lines.color.y; it.color[2] = lines.color.z;
        it.opacity = lines.opacity;
        it.lineHalfWidth = (float)(0.5 * lines.lineWidth);
        it.solid = lines.opacity >= 1 ? 1 : 0;
        items.push_back(it);
    }
    for (BKPointObject *points in _pointObjects) {   // 2026-11-14
        if (!points.visible || !(points.opacity > 0) || !(points.pointSize > 0)) continue;
        if (![points prepareBufferOnDevice:_device]) continue;
        meshpass::Item it;
        it.kind = meshpass::ItemKind::Points;
        simd_float3 lo, hi;
        [points getPatientBoundsMin:&lo max:&hi];
        bounds(it, lo, hi);
        it.vertices = wrap([points pointBuffer]);
        it.vertexCount = (uint32_t)(points.pointCount * 6);
        simd_float4x4 placement = points.transform;
        memcpy(it.model, &placement, sizeof it.model);
        it.color[0] = points.color.x; it.color[1] = points.color.y; it.color[2] = points.color.z;
        it.opacity = points.opacity;
        it.lineHalfWidth = (float)(0.5 * points.pointSize);
        it.solid = points.opacity >= 1 ? 1 : 0;
        items.push_back(it);
    }

    std::unique_ptr<gpu::Texture> color, distance;
    if (vk) {   // the pictures are made on the Vulkan device, then copied into the caller's textures
        gpu::TextureDesc cd;
        cd.format = gpu::Format::RGBA8Unorm;
        cd.width = (uint32_t)width; cd.height = (uint32_t)height;
        cd.usage = gpu::UsageRenderTarget | gpu::UsageCopySource;
        color = _vk->makeTexture(cd, nullptr);
        if (distanceTexture) {
            cd.format = gpu::Format::R32Float;
            distance = _vk->makeTexture(cd, nullptr);
        }
    } else {
        color = gpu::BKGPUMetalWrapTexture(*_gpu, colorTexture);
        distance = distanceTexture ? gpu::BKGPUMetalWrapTexture(*_gpu, distanceTexture) : nullptr;
    }
    if (!color || (distanceTexture && !distance)) {
        if (error) *error = BKMeshRenderError(43, @"The output texture format is not supported (use RGBA8 or BGRA8, and R32Float for the ray distance).");
        return NO;
    }
    meshpass::Frame frame;
    frame.camera = [self meshCamera];
    frame.lighting = (BKMeshLighting){ _ambient, _diffuse, _specular, _specularPower };
    frame.color = color.get();
    frame.distance = distance.get();
    frame.clear = clear ? 1 : 0;
    frame.clearColor[0] = clearColor.x; frame.clearColor[1] = clearColor.y; frame.clearColor[2] = clearColor.z; frame.clearColor[3] = clearColor.w;
    frame.area[0] = (int32_t)area.origin.x; frame.area[1] = (int32_t)area.origin.y;
    frame.area[2] = (int32_t)area.size.width; frame.area[3] = (int32_t)area.size.height;
    int32_t result;
    if (vk) {
        double t0 = gpu::BKGPUEngineNowMs();
        std::unique_ptr<gpu::CommandList> list = _vk->begin(nullptr);
        result = list ? _vkPass->encode(*list, frame, items.data(), items.size()) : (int32_t)meshpass::NoEncoder;
        if (result == meshpass::Ok && _vk->submit(*list, true) != gpu::Status::Ok) result = meshpass::NoEncoder;
        if (result == meshpass::Ok) {
            std::vector<uint8_t> pixels, rays;
            bool bgra = vkFormat == gpu::Format::BGRA8Unorm;
            if (!gpu::BKGPUReadTexture(*_vk, *color, &pixels) || (distance && !gpu::BKGPUReadTexture(*_vk, *distance, &rays))) {
                result = meshpass::NoEncoder;
            } else {
                if (bgra) gpu::BKGPUSwapRedBlue(pixels.data(), width * height);
                gpu::BKGPUStampTestMarker(pixels.data(), (uint32_t)width, (uint32_t)height, bgra);
                if (!gpu::BKGPUBlitBytesToMetalTexture(commandBuffer, colorTexture, pixels.data(), width * 4) ||
                    (distance && !gpu::BKGPUBlitBytesToMetalTexture(commandBuffer, distanceTexture, rays.data(), width * 4)))
                    result = meshpass::NoEncoder;
            }
        }
        gpu::BKGPUEngineLogFrame("BKMeshRenderer", (uint32_t)width, (uint32_t)height, gpu::BKGPUEngineNowMs() - t0);
    } else {
        std::unique_ptr<gpu::CommandList> list = gpu::BKGPUMetalCommandList(*_gpu, commandBuffer);
        result = list ? _pass->encode(*list, frame, items.data(), items.size()) : (int32_t)meshpass::NoEncoder;
    }   // the list ends its encoder here; the caller commits the command buffer
    switch (result) {
        case meshpass::Ok: return YES;
        case meshpass::ZeroDirection: return BKMeshCameraStatusOK(BKMeshCameraZeroDirection, error);
        case meshpass::UpParallel: return BKMeshCameraStatusOK(BKMeshCameraUpParallel, error);
        case meshpass::ZeroFieldOfView: return BKMeshCameraStatusOK(BKMeshCameraZeroFieldOfView, error);
        case meshpass::NoEncoder:
            if (error) *error = BKMeshRenderError(35, @"The GPU could not start drawing the meshes.");
            return NO;
        case meshpass::NoDepthTarget:
            if (error) *error = BKMeshRenderError(42, @"Not enough GPU memory for the depth buffer.");
            return NO;
        default:
            if (error) *error = BKMeshRenderError(41, @"The GPU could not prepare the mesh drawing programs.");
            return NO;
    }
}

- (BKRenderResult *)renderWithWidth:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error
{
    if (width == 0 || height == 0) {
        if (error) *error = BKMeshRenderError(33, @"The output image size is zero.");
        return nil;
    }
    // GPU-only render targets, then copied into CPU-readable buffers (works on every Mac,
    // including Intel GPUs that cannot share textures with the CPU).
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    cd.usage = MTLTextureUsageRenderTarget;
    cd.storageMode = MTLStorageModePrivate;
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:width height:height mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> color = [_device newTextureWithDescriptor:cd];
    id<MTLTexture> distance = [_device newTextureWithDescriptor:dd];
    id<MTLBuffer> colorOut = [_device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> distanceOut = [_device newBufferWithLength:width * height * sizeof(float) options:MTLResourceStorageModeShared];
    if (!color || !distance || !colorOut || !distanceOut) {
        if (error) *error = BKMeshRenderError(37, @"Not enough memory for the output image.");
        return nil;
    }

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    if (![self encodeRenderToColorTexture:color rayDistanceTexture:distance commandBuffer:cb
                                    clear:YES clearColor:simd_make_float4(0, 0, 0, 0) error:error]) return nil;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:colorOut destinationOffset:0 destinationBytesPerRow:width * 4 destinationBytesPerImage:width * height * 4];
    [blit copyFromTexture:distance sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:distanceOut destinationOffset:0 destinationBytesPerRow:width * sizeof(float) destinationBytesPerImage:width * height * sizeof(float)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) {
        if (error) *error = cb.error ?: BKMeshRenderError(38, @"The GPU failed to draw the meshes.");
        return nil;
    }
    return [[BKRenderResult alloc] initWithWidth:width height:height
                                            rgba:[NSData dataWithBytes:colorOut.contents length:width * height * 4]
                                          floats:[NSData dataWithBytes:distanceOut.contents length:width * height * sizeof(float)]];
}

#pragma mark Picking

simd_float3 BKMeshUnprojectPixel(BKProjection projection, simd_float3 position, simd_float3 right,
                                 simd_float3 up, simd_float3 forward, float halfWidth, float halfHeight,
                                 float ndcX, float ndcY, float rayDistance)
{
    if (projection == BKProjectionPerspective) {
        // The pixel's ray from the eye (same as the vertex shader's projection, inverted).
        simd_float3 dir = simd_normalize(forward + right * (ndcX * halfWidth) + up * (ndcY * halfHeight));
        return position + dir * rayDistance;
    }
    return position + right * (ndcX * halfWidth) + up * (ndcY * halfHeight) + forward * rayDistance;
}

// What: see the header. One offscreen render with the ray-distance output, one pixel read.
- (BOOL)pickPatientPoint:(simd_float3 *)point atPixelX:(double)x y:(double)y
                   width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error
{
    if (point == NULL || !(x >= 0) || !(y >= 0) || x >= width || y >= height) return NO;
    BKRenderResult *result = [self renderWithWidth:width height:height error:error];
    if (result == nil) return NO;
    NSUInteger px = (NSUInteger)floor(x), py = (NSUInteger)floor(y);
    float distance = [result valueAtX:px y:py];
    if (!isfinite(distance)) return NO;   // background or only see-through surfaces

    // Drawing area and camera exactly as -encodeRenderToColorTexture: uses them.
    CGRect area = CGRectMake(0, 0, width, height);
    if (!CGRectIsEmpty(_viewport)) area = CGRectIntersection(CGRectIntegral(_viewport), area);
    if (CGRectIsEmpty(area)) return NO;
    simd_float3 right, up, forward;
    if (![self getCameraRight:&right up:&up forward:&forward error:error]) return NO;
    float halfWidth, halfHeight;   // 2026-11-25 (M3): the same rule the drawing uses (BKMeshDrawCore)
    BKMeshCamera meshCamera = [self meshCamera];
    BKMeshCameraHalfSize(&meshCamera, (float)area.size.width, (float)area.size.height, &halfWidth, &halfHeight);
    // Pixel centre -> -1..1 inside the drawing area (y up).
    float ndcX = (float)(((px + 0.5) - area.origin.x) / area.size.width * 2.0 - 1.0);
    float ndcY = (float)(1.0 - ((py + 0.5) - area.origin.y) / area.size.height * 2.0);
    *point = BKMeshUnprojectPixel(_projection, BKMeshFloat3(_cameraPosition), right, up, forward,
                                  halfWidth, halfHeight, ndcX, ndcY, distance);
    return YES;
}

#pragma mark Tests

- (NSUInteger)gpuUniformBlockSize
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

+ (NSUInteger)cpuUniformBlockSize
{
    return sizeof(BKMeshUniforms);
}

@end
