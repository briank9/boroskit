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

NSString *BKMeshShaderSource(void); // BKMeshShaderSource.mm

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

#pragma mark - BKMeshObject

// Renderer-only part of BKMeshObject: the GPU copy of its mesh.
@interface BKMeshObject ()
- (BOOL)prepareBuffersOnDevice:(id<MTLDevice>)device;
- (id<MTLBuffer>)vertexBuffer;
- (id<MTLBuffer>)indexBuffer;
@end

@implementation BKMeshObject {
    // GPU copy of the mesh (owned by whichever renderer uploaded it).
    id<MTLBuffer> _vertexBuffer;
    id<MTLBuffer> _indexBuffer;
    __weak BKMesh *_uploadedMesh;     // which mesh / version / GPU the buffers hold
    NSUInteger _uploadedVersion;
    __weak id<MTLDevice> _uploadedDevice;
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

#pragma mark - BKMeshRenderer

// What the draw loop needs per visible object.
@interface BKMeshDrawItem : NSObject
@property (nonatomic, strong) BKMeshObject *object;      // a mesh, or
@property (nonatomic, strong) BKLineObject *lineObject;  // a set of lines
@property (nonatomic) float sortDistance;   // along the view direction, for back-to-front order
@end
@implementation BKMeshDrawItem
@end

@implementation BKMeshRenderer {
    id<MTLLibrary> _library;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _sizePipeline;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;  // per target format / pass
    id<MTLDepthStencilState> _opaqueDepthState;       // test + write depth
    id<MTLDepthStencilState> _transparentDepthState;  // test only
    id<MTLTexture> _depthTexture;                     // reused while the size stays the same
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
            library = [device newLibraryWithSource:BKMeshShaderSource() options:[[MTLCompileOptions alloc] init] error:error];
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
        if (error) *error = BKMeshRenderError(30, @"No Metal GPU is available on this device.");
        return nil;
    }
    _library = [[self class] libraryForDevice:_device error:error];
    if (!_library) return nil;
    _sizePipeline = [_device newComputePipelineStateWithFunction:[_library newFunctionWithName:@"bk_mesh_uniforms_size"] error:error];
    if (!_sizePipeline) return nil;
    _queue = [_device newCommandQueue];
    _pipelines = [NSMutableDictionary dictionary];

    MTLDepthStencilDescriptor *depth = [[MTLDepthStencilDescriptor alloc] init];
    depth.depthCompareFunction = MTLCompareFunctionLess;
    depth.depthWriteEnabled = YES;
    _opaqueDepthState = [_device newDepthStencilStateWithDescriptor:depth];
    depth.depthWriteEnabled = NO;
    _transparentDepthState = [_device newDepthStencilStateWithDescriptor:depth];

    _objects = @[];
    _lineObjects = @[];
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

// What: the orthonormal camera frame (right, up, forward), built like the volume
// renderer builds it. Returns NO + error for a zero or degenerate camera.
- (BOOL)getCameraRight:(simd_float3 *)right up:(simd_float3 *)up forward:(simd_float3 *)forward error:(NSError **)error
{
    simd_float3 f = BKMeshFloat3(_cameraDirection), u = BKMeshFloat3(_cameraUp);
    if (simd_length(f) < 1e-6f) {
        if (error) *error = BKMeshRenderError(31, @"The camera direction is zero.");
        return NO;
    }
    f = simd_normalize(f);
    simd_float3 r = simd_cross(f, u);
    if (simd_length(r) < 1e-6f) {
        if (error) *error = BKMeshRenderError(32, @"The camera up vector is parallel to the viewing direction.");
        return NO;
    }
    r = simd_normalize(r);
    *right = r;
    *up = simd_cross(r, f);
    *forward = f;
    return YES;
}

#pragma mark Pipelines

// What: the drawing pipeline for one target colour format, with or without the
// ray-distance output, for the solid or the see-through pass. Built once and cached.
- (id<MTLRenderPipelineState>)pipelineForColorFormat:(MTLPixelFormat)format withDistance:(BOOL)withDistance
                                         transparent:(BOOL)transparent error:(NSError **)error
{
    NSString *key = [NSString stringWithFormat:@"%lu-%d-%d", (unsigned long)format, withDistance, transparent];
    id<MTLRenderPipelineState> pipeline = _pipelines[key];
    if (pipeline) return pipeline;
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [_library newFunctionWithName:@"bk_mesh_vertex"];
    d.fragmentFunction = [_library newFunctionWithName:withDistance ? @"bk_mesh_fragment_distance" : @"bk_mesh_fragment"];
    [self configurePipeline:d colorFormat:format withDistance:withDistance transparent:transparent];
    pipeline = [_device newRenderPipelineStateWithDescriptor:d error:error];
    if (pipeline) _pipelines[key] = pipeline;
    return pipeline;
}

// What: the same as above for lines (screen-aligned rectangles, flat colour).
- (id<MTLRenderPipelineState>)linePipelineForColorFormat:(MTLPixelFormat)format withDistance:(BOOL)withDistance
                                             transparent:(BOOL)transparent error:(NSError **)error
{
    NSString *key = [NSString stringWithFormat:@"line-%lu-%d-%d", (unsigned long)format, withDistance, transparent];
    id<MTLRenderPipelineState> pipeline = _pipelines[key];
    if (pipeline) return pipeline;
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [_library newFunctionWithName:@"bk_line_vertex"];
    d.fragmentFunction = [_library newFunctionWithName:withDistance ? @"bk_line_fragment_distance" : @"bk_line_fragment"];
    [self configurePipeline:d colorFormat:format withDistance:withDistance transparent:transparent];
    pipeline = [_device newRenderPipelineStateWithDescriptor:d error:error];
    if (pipeline) _pipelines[key] = pipeline;
    return pipeline;
}

// What: the blending/attachment settings shared by the mesh and line pipelines.
- (void)configurePipeline:(MTLRenderPipelineDescriptor *)d colorFormat:(MTLPixelFormat)format
             withDistance:(BOOL)withDistance transparent:(BOOL)transparent
{
    d.colorAttachments[0].pixelFormat = format;
    // Premultiplied "over" blending: result = colour + (1 - alpha) * what is behind.
    // For solid objects (alpha 1) this simply replaces what is behind.
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    if (withDistance) {
        d.colorAttachments[1].pixelFormat = MTLPixelFormatR32Float;
        // See-through surfaces must not count as "the surface that stops the ray".
        d.colorAttachments[1].writeMask = transparent ? MTLColorWriteMaskNone : MTLColorWriteMaskAll;
    }
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
}

// What: a depth buffer of the given size, kept between frames. Why: the depth test
// needs one; creating it every frame would waste memory bandwidth.
- (id<MTLTexture>)depthTextureWithWidth:(NSUInteger)w height:(NSUInteger)h
{
    if (_depthTexture && _depthTexture.width == w && _depthTexture.height == h) return _depthTexture;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                 width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    _depthTexture = [_device newTextureWithDescriptor:d];
    return _depthTexture;
}

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
    simd_float3 camera = BKMeshFloat3(_cameraPosition);
    BOOL perspective = _projection == BKProjectionPerspective;

    // 1. Visible objects, uploaded, with their depth extent along the view direction.
    NSMutableArray<BKMeshDrawItem *> *opaque = [NSMutableArray array], *transparent = [NSMutableArray array];
    float nearest = INFINITY, farthest = -INFINITY;
    for (BKMeshObject *object in _objects) {
        if (!object.visible || !(object.opacity > 0)) continue;
        if (![object prepareBuffersOnDevice:_device]) continue;
        simd_float3 lo, hi;
        [object getPatientBoundsMin:&lo max:&hi];
        for (int i = 0; i < 8; i++) {
            simd_float3 c = simd_make_float3((i & 1) ? hi.x : lo.x, (i & 2) ? hi.y : lo.y, (i & 4) ? hi.z : lo.z);
            float z = simd_dot(c - camera, forward);
            nearest = MIN(nearest, z);
            farthest = MAX(farthest, z);
        }
        BKMeshDrawItem *item = [[BKMeshDrawItem alloc] init];
        item.object = object;
        item.sortDistance = simd_dot((lo + hi) * 0.5f - camera, forward);
        [(object.opacity >= 1 ? opaque : transparent) addObject:item];
    }
    // Lines: same depth extent bookkeeping; solid ones go with the solid pass.
    NSMutableArray<BKMeshDrawItem *> *opaqueLines = [NSMutableArray array];
    for (BKLineObject *lines in _lineObjects) {
        if (!lines.visible || !(lines.opacity > 0) || !(lines.lineWidth > 0)) continue;
        if (![lines prepareBufferOnDevice:_device]) continue;
        simd_float3 lo, hi;
        [lines getPatientBoundsMin:&lo max:&hi];
        for (int i = 0; i < 8; i++) {
            simd_float3 c = simd_make_float3((i & 1) ? hi.x : lo.x, (i & 2) ? hi.y : lo.y, (i & 4) ? hi.z : lo.z);
            float z = simd_dot(c - camera, forward);
            nearest = MIN(nearest, z);
            farthest = MAX(farthest, z);
        }
        BKMeshDrawItem *item = [[BKMeshDrawItem alloc] init];
        item.lineObject = lines;
        item.sortDistance = simd_dot((lo + hi) * 0.5f - camera, forward);
        [(lines.opacity >= 1 ? opaqueLines : transparent) addObject:item];
    }
    // See-through objects: farthest first, so nearer ones are blended over farther ones.
    [transparent sortUsingComparator:^NSComparisonResult(BKMeshDrawItem *a, BKMeshDrawItem *b) {
        return a.sortDistance > b.sortDistance ? NSOrderedAscending : (a.sortDistance < b.sortDistance ? NSOrderedDescending : NSOrderedSame);
    }];

    // 2. Depth range: just enclose the scene (a tight range keeps the depth test precise).
    // Perspective cannot see behind the eye, so the near distance stays positive.
    float margin = 1.0f + 0.01f * MAX(farthest - nearest, 0.0f);
    float nearDistance = nearest - margin, farDistance = farthest + margin;
    if (perspective) {
        farDistance = MAX(farDistance, 1e-3f);
        nearDistance = MAX(nearDistance, farDistance * 1e-4f);
    }
    BOOL anything = (opaque.count + opaqueLines.count + transparent.count) > 0 && isfinite(nearDistance) && isfinite(farDistance) && farDistance > nearDistance;

    // 3. The render pass: colour (+ ray distance) + depth.
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = colorTexture;
    pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(clearColor.x, clearColor.y, clearColor.z, clearColor.w);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (distanceTexture) {
        pass.colorAttachments[1].texture = distanceTexture;
        pass.colorAttachments[1].loadAction = MTLLoadActionClear;
        pass.colorAttachments[1].clearColor = MTLClearColorMake(INFINITY, 0, 0, 0);
        pass.colorAttachments[1].storeAction = MTLStoreActionStore;
    }
    pass.depthAttachment.texture = [self depthTextureWithWidth:width height:height];
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderPipelineState> opaquePipeline = [self pipelineForColorFormat:colorTexture.pixelFormat withDistance:distanceTexture != nil transparent:NO error:error];
    id<MTLRenderPipelineState> transparentPipeline = [self pipelineForColorFormat:colorTexture.pixelFormat withDistance:distanceTexture != nil transparent:YES error:error];
    id<MTLRenderPipelineState> opaqueLinePipeline = [self linePipelineForColorFormat:colorTexture.pixelFormat withDistance:distanceTexture != nil transparent:NO error:error];
    id<MTLRenderPipelineState> transparentLinePipeline = [self linePipelineForColorFormat:colorTexture.pixelFormat withDistance:distanceTexture != nil transparent:YES error:error];
    if (!opaquePipeline || !transparentPipeline || !opaqueLinePipeline || !transparentLinePipeline) return NO;

    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!enc) {
        if (error) *error = BKMeshRenderError(35, @"The GPU could not start drawing the meshes.");
        return NO;
    }
    enc.label = @"BKMeshRenderer";
    // Both sides of every triangle are drawn: mesh files often have mixed-up sides.
    [enc setCullMode:MTLCullModeNone];
    // Only the drawing area (whole image unless a viewport was set).
    [enc setViewport:(MTLViewport){area.origin.x, area.origin.y, area.size.width, area.size.height, 0.0, 1.0}];
    [enc setScissorRect:(MTLScissorRect){(NSUInteger)area.origin.x, (NSUInteger)area.origin.y,
                                         (NSUInteger)area.size.width, (NSUInteger)area.size.height}];

    if (anything) {
        // Shared camera part of the uniforms.
        BKMeshUniforms base;
        memset(&base, 0, sizeof base);
        base.cameraPosition = simd_make_float4(camera, 1);
        base.cameraRight = simd_make_float4(right, 0);
        base.cameraUp = simd_make_float4(up, 0);
        base.cameraForward = simd_make_float4(forward, 0);
        float aspect = (float)area.size.width / (float)area.size.height;
        if (perspective) {
            // Same as the volume renderer: vertical angle given, horizontal follows the image.
            base.halfHeight = tanf(0.5f * (float)_fieldOfView * (float)M_PI / 180.0f);
            base.halfWidth = base.halfHeight * aspect;
        } else {
            base.halfWidth = 0.5f * (float)_viewWidth;
            base.halfHeight = 0.5f * (float)_viewHeight;
        }
        if (!(base.halfWidth > 0) || !(base.halfHeight > 0)) {
            [enc endEncoding];
            if (error) *error = BKMeshRenderError(36, @"The camera's field of view is zero.");
            return NO;
        }
        base.nearDistance = nearDistance;
        base.farDistance = farDistance;
        base.ambient = _ambient;
        base.diffuse = _diffuse;
        base.specular = _specular;
        base.specularPower = _specularPower;
        base.projection = _projection;
        base.lit = 1;
        base.viewportWidth = (float)area.size.width;
        base.viewportHeight = (float)area.size.height;

        // Pass 0: solid meshes; pass 1: solid lines; pass 2: everything see-through,
        // farthest first (meshes and lines mixed, so they blend in the right order).
        NSArray *passes = @[opaque, opaqueLines, transparent];
        for (NSUInteger p = 0; p < 3; p++) {
            BOOL see = (p == 2);
            [enc setDepthStencilState:see ? _transparentDepthState : _opaqueDepthState];
            for (BKMeshDrawItem *item in passes[p]) {
                if (item.lineObject) {
                    BKLineObject *l = item.lineObject;
                    BKMeshUniforms u = base;
                    u.model = l.transform;
                    u.normalMatrix = matrix_identity_float4x4;
                    u.color = simd_make_float4(l.color, MIN(MAX(l.opacity, 0.0f), 1.0f));
                    u.lit = 0;
                    u.lineHalfWidth = (float)(0.5 * l.lineWidth);
                    [enc setRenderPipelineState:see ? transparentLinePipeline : opaqueLinePipeline];
                    [enc setVertexBuffer:[l pointBuffer] offset:0 atIndex:0];
                    [enc setVertexBytes:&u length:sizeof u atIndex:1];
                    [enc setFragmentBytes:&u length:sizeof u atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:l.segmentCount * 6];
                    continue;
                }
                [enc setRenderPipelineState:see ? transparentPipeline : opaquePipeline];
                BKMeshObject *o = item.object;
                BKMesh *mesh = o.mesh;
                BKMeshUniforms u = base;
                u.model = o.transform;
                simd_float3x3 linear = simd_matrix(o.transform.columns[0].xyz, o.transform.columns[1].xyz, o.transform.columns[2].xyz);
                simd_float3x3 nm = simd_determinant(linear) != 0 ? simd_transpose(simd_inverse(linear)) : linear;
                u.normalMatrix = simd_matrix(simd_make_float4(nm.columns[0], 0), simd_make_float4(nm.columns[1], 0),
                                             simd_make_float4(nm.columns[2], 0), simd_make_float4(0, 0, 0, 1));
                u.color = simd_make_float4(o.color, MIN(MAX(o.opacity, 0.0f), 1.0f));
                u.useVertexColors = (o.useVertexColors && mesh.colors) ? 1 : 0;
                u.hasNormals = mesh.normals ? 1 : 0;
                u.lit = o.lit ? 1 : 0;
                if (o.usesOwnMaterial) {
                    u.ambient = o.ambient;
                    u.diffuse = o.diffuse;
                    u.specular = o.specular;
                    u.specularPower = o.specularPower;
                }
                [enc setVertexBuffer:[o vertexBuffer] offset:0 atIndex:0];
                [enc setVertexBytes:&u length:sizeof u atIndex:1];
                [enc setFragmentBytes:&u length:sizeof u atIndex:1];
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:mesh.triangleCount * 3
                                 indexType:MTLIndexTypeUInt32 indexBuffer:[o indexBuffer] indexBufferOffset:0];
            }
        }
    }
    [enc endEncoding];
    return YES;
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
