// BorosKitGoldenTests: BKGoldenMetal implementation (see BKGoldenMetal.h).
// Original BorosKit code written for this project; contains no third-party code.

#import "BKGoldenMetal.h"
#import "BorosKitRender.h"
#import "BorosKitDisplay.h"
#import "BorosKitMesh.h"
#import "BorosKitMeshRender.h"
#import "BorosKitSurface.h"

// What: an NSError for the harness. Why: plain-language failure messages in test logs.
static NSError *BKGoldenError(NSString *message)
{
    return [NSError errorWithDomain:@"BKGoldenErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// What: three doubles -> N3Vector. Why: the renderers' public API takes N3Vector; the
// harness only builds values of that plain struct, it does not use the N3 maths.
static N3Vector BKGoldenVector(const double v[3])
{
    return N3VectorMake(v[0], v[1], v[2]);
}

BKGoldenMesh BKGoldenMeshFromBKMesh(BKMesh *mesh)
{
    BKGoldenMesh m = {0};
    m.vertexCount = mesh.vertexCount;
    m.triangleCount = mesh.triangleCount;
    m.positions = malloc(sizeof(float) * 3 * m.vertexCount + 4);
    m.normals = mesh.normals ? malloc(sizeof(float) * 3 * m.vertexCount + 4) : NULL;
    m.indices = malloc(sizeof(uint32_t) * 3 * m.triangleCount + 4);
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) {
        // BKMesh stores simd_float3 (16 bytes each); the plain mesh packs 3 floats.
        simd_float3 p = mesh.vertices[i];
        m.positions[3 * i] = p.x; m.positions[3 * i + 1] = p.y; m.positions[3 * i + 2] = p.z;
        if (m.normals) {
            simd_float3 n = mesh.normals[i];
            m.normals[3 * i] = n.x; m.normals[3 * i + 1] = n.y; m.normals[3 * i + 2] = n.z;
        }
    }
    memcpy(m.indices, mesh.indices, sizeof(uint32_t) * 3 * m.triangleCount);
    return m;
}

BKMesh *BKMeshFromGoldenMesh(const BKGoldenMesh *m)
{
    simd_float3 *v = malloc(sizeof(simd_float3) * (m->vertexCount + 1));
    simd_float3 *n = m->normals ? malloc(sizeof(simd_float3) * (m->vertexCount + 1)) : NULL;
    for (uint64_t i = 0; i < m->vertexCount; i++) {
        v[i] = simd_make_float3(m->positions[3 * i], m->positions[3 * i + 1], m->positions[3 * i + 2]);
        if (n) n[i] = simd_make_float3(m->normals[3 * i], m->normals[3 * i + 1], m->normals[3 * i + 2]);
    }
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:m->vertexCount indices:m->indices
                                         indexCount:m->triangleCount * 3 normals:n colors:NULL error:NULL];
    free(v);
    free(n);
    return mesh;
}

// What: copies an RGBA8 NSData into a plain U8 x4 image. Why: hand results to the comparers.
static BKGoldenImage BKGoldenImageFromRGBA(NSData *data, NSUInteger width, NSUInteger height)
{
    BKGoldenImage image = bk_golden_image_make((uint32_t)width, (uint32_t)height, 4, BKGoldenFormatU8);
    if (image.data) memcpy(image.data, data.bytes, MIN(data.length, bk_golden_image_bytes(&image)));
    return image;
}

// Same for one float per pixel.
static BKGoldenImage BKGoldenImageFromFloats(NSData *data, NSUInteger width, NSUInteger height)
{
    BKGoldenImage image = bk_golden_image_make((uint32_t)width, (uint32_t)height, 1, BKGoldenFormatF32);
    if (image.data) memcpy(image.data, data.bytes, MIN(data.length, bk_golden_image_bytes(&image)));
    return image;
}

@implementation BKGoldenMetalProducer {
    BKVolumeRenderer *_volumeRenderer;
    BKSurfaceExtractor *_extractor;
    BKMeshRenderer *_meshRenderer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device volume:(const BKGoldenVolume *)volume error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device;
    _volumeTexture = [[BKVolumeTexture alloc] initWithFloatVoxels:volume->voxels width:volume->width height:volume->height
                                                            depth:volume->depth patientToVoxel:volume->patientToVoxel
                                                  minPixelSpacing:volume->minSpacing outOfBoundsValue:volume->outOfBoundsValue
                                                           device:device error:error];
    if (!_volumeTexture) return nil;
    _volumeRenderer = [[BKVolumeRenderer alloc] initWithDevice:device error:error];
    _extractor = [[BKSurfaceExtractor alloc] initWithDevice:device error:error];
    _meshRenderer = [[BKMeshRenderer alloc] initWithDevice:device error:error];
    if (!_volumeRenderer || !_extractor || !_meshRenderer) return nil;
    _volumeRenderer.volumeTexture = _volumeTexture;
    return self;
}

- (BOOL)renderVolumeCase:(const BKGoldenVolumeCase *)c rgba:(BKGoldenImage *)rgba values:(BKGoldenImage *)values
                   error:(NSError **)error
{
    BKVolumeRenderer *r = _volumeRenderer;
    // A fresh volume assignment resets crop box and extra clip planes to their defaults,
    // so one case can never leak settings into the next.
    r.volumeTexture = _volumeTexture;
    r.mode = (BKRenderMode)c->mode;
    r.projection = (BKProjection)c->projection;
    r.cameraPosition = BKGoldenVector(c->cameraPosition);
    r.cameraDirection = BKGoldenVector(c->cameraDirection);
    r.cameraUp = BKGoldenVector(c->cameraUp);
    r.viewWidth = c->viewWidth;
    r.viewHeight = c->viewHeight;
    r.fieldOfView = c->fieldOfView;
    r.sampleSpacing = c->sampleSpacing;
    r.slabEnabled = c->slabEnabled != 0;
    r.slabPlane = N3PlaneMake(BKGoldenVector(c->slabPoint), BKGoldenVector(c->slabNormal));
    r.slabThickness = c->slabThickness;
    r.clipPlaneEnabled = NO;
    r.windowCenter = c->windowCenter;
    r.windowWidth = c->windowWidth;
    r.shadingEnabled = c->shading != 0;
    r.opacityUnitDistance = c->opacityUnitDistance;
    r.skipsEmptySpace = c->skipEmptySpace != 0;
    r.missValue = NAN;
    r.manualFiltering = _manualFiltering;
    if (c->useTransferFunction) {
        BKTransferFunction *tf = [[BKTransferFunction alloc] init];
        for (uint32_t i = 0; i < kBKGoldenColorPointCount; i++) {
            const BKGoldenColorPoint *p = &kBKGoldenColorPoints[i];
            [tf addColorPointAtValue:p->value red:p->red green:p->green blue:p->blue];
        }
        for (uint32_t i = 0; i < kBKGoldenOpacityPointCount; i++)
            [tf addOpacityPointAtValue:kBKGoldenOpacityPoints[i].value opacity:kBKGoldenOpacityPoints[i].opacity];
        r.transferFunction = tf;
    } else {
        r.transferFunction = nil;
    }
    N3Plane planes[2];
    for (int32_t i = 0; i < c->clipPlaneCount && i < 2; i++)
        planes[i] = N3PlaneMake(BKGoldenVector(c->clipPlanes[i]), BKGoldenVector(c->clipPlanes[i] + 3));
    [r setClipPlanes:planes count:(NSUInteger)MAX(0, MIN(c->clipPlaneCount, 2))];

    BKRenderResult *result = [r renderWithWidth:c->width height:c->height error:error];
    if (!result) return NO;
    *rgba = BKGoldenImageFromRGBA(result.rgba8Data, result.width, result.height);
    *values = BKGoldenImageFromFloats(result.floatData, result.width, result.height);
    return rgba->data && values->data;
}

- (BOOL)renderImageCase:(const BKGoldenImageCase *)c volume:(const BKGoldenVolume *)volume rgba:(BKGoldenImage *)rgba
                  error:(NSError **)error
{
    if (c->sliceIndex >= volume->depth) {
        if (error) *error = BKGoldenError(@"Slice index outside the phantom.");
        return NO;
    }
    BKImageLayerRenderer *renderer = [[BKImageLayerRenderer alloc] initWithDevice:_device error:error];
    if (!renderer) return NO;
    const float *slice = volume->voxels + (size_t)c->sliceIndex * volume->width * volume->height;
    renderer.image = [[BKImage alloc] initWithFloatPixels:slice width:volume->width height:volume->height
                                            pixelSpacingX:volume->spacing[0] pixelSpacingY:volume->spacing[1]];
    renderer.windowCenter = c->windowCenter;
    renderer.windowWidth = c->windowWidth;
    renderer.interpolation = c->linear ? BKImageInterpolationLinear : BKImageInterpolationNearest;
    renderer.invert = c->invert != 0;
    if (c->useColorTable) {
        uint8_t table[768];
        bk_golden_color_table(table);
        renderer.colorTable = [NSData dataWithBytes:table length:sizeof table];
    }
    renderer.backgroundColor = BKColorMake(c->background[0], c->background[1], c->background[2], c->background[3]);
    BKViewTransform t = BKViewTransformMakeFit(volume->width, volume->height, c->outWidth, c->outHeight);
    t.pixelSpacingX = volume->spacing[0];
    t.pixelSpacingY = volume->spacing[1];
    t.zoom = c->zoom;
    t.panX = c->panX;
    t.panY = c->panY;
    t.rotationDegrees = c->rotationDegrees;
    t.flipHorizontal = c->flipHorizontal != 0;
    t.flipVertical = c->flipVertical != 0;
    renderer.viewTransform = t;
    NSData *pixels = [renderer renderRGBA8WithWidth:c->outWidth height:c->outHeight scale:1.0 error:error];
    if (!pixels) return NO;
    *rgba = BKGoldenImageFromRGBA(pixels, c->outWidth, c->outHeight);
    return rgba->data != NULL;
}

- (BKMesh *)extractSurfaceCase:(const BKGoldenSurfaceCase *)c error:(NSError **)error
{
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.resolution = c->resolution;
    options.scanSmoothing = c->smoothing;
    options.sampling = c->manualSampling ? BKSurfaceSamplingManualTrilinear : BKSurfaceSamplingHardwareLinear;
    return [_extractor extractSurfacesFromVolume:_volumeTexture thresholds:@[@(c->threshold)] options:options
                                         timings:NULL error:error].firstObject;
}

- (BOOL)renderMeshCase:(const BKGoldenMeshRenderCase *)c mesh:(BKMesh *)mesh rgba:(BKGoldenImage *)rgba
              distance:(BKGoldenImage *)distance error:(NSError **)error
{
    BKMeshObject *object = [[BKMeshObject alloc] initWithMesh:mesh];
    object.color = simd_make_float3(c->color[0], c->color[1], c->color[2]);
    object.opacity = c->opacity;
    _meshRenderer.objects = @[object];
    _meshRenderer.lineObjects = @[];
    _meshRenderer.viewport = CGRectZero;
    _meshRenderer.projection = (BKProjection)c->projection;
    _meshRenderer.cameraPosition = BKGoldenVector(c->cameraPosition);
    _meshRenderer.cameraDirection = BKGoldenVector(c->cameraDirection);
    _meshRenderer.cameraUp = BKGoldenVector(c->cameraUp);
    _meshRenderer.viewWidth = c->viewWidth;
    _meshRenderer.viewHeight = c->viewHeight;
    _meshRenderer.fieldOfView = c->fieldOfView;
    BKRenderResult *result = [_meshRenderer renderWithWidth:c->width height:c->height error:error];
    if (!result) return NO;
    *rgba = BKGoldenImageFromRGBA(result.rgba8Data, result.width, result.height);
    *distance = BKGoldenImageFromFloats(result.floatData, result.width, result.height);
    return rgba->data && distance->data;
}

- (NSData *)storedVolumeStepsWithError:(NSError **)error
{
    id<MTLTexture> texture = _volumeTexture.texture;
    NSUInteger w = texture.width, h = texture.height, d = texture.depth;
    id<MTLBuffer> buffer = [_device newBufferWithLength:w * h * d * sizeof(uint16_t) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [_device newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, d) toBuffer:buffer destinationOffset:0
   destinationBytesPerRow:w * sizeof(uint16_t) destinationBytesPerImage:w * h * sizeof(uint16_t)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) {
        if (error) *error = cb.error ?: BKGoldenError(@"Could not read the volume back from the GPU.");
        return nil;
    }
    NSMutableData *floats = [NSMutableData dataWithLength:w * h * d * sizeof(float)];
    const uint16_t *s = buffer.contents;
    float *f = floats.mutableBytes;
    for (NSUInteger i = 0; i < w * h * d; i++) f[i] = (float)s[i];
    return floats;
}

@end
