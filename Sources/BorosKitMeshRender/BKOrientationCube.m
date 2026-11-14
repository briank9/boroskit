// BorosKitMeshRender: BKOrientationCube - see include/BKOrientationCube.h.
// Original BorosKit code written for this project; contains no third-party code.
// Thin Apple layer: every number comes from the plain-C core BKOrientationCubeCore.c.

#import "BKOrientationCube.h"
#import "BKMeshRenderer.h"
#import "BKMesh.h"
#import "BKMetalDevice.h"
#import "BKVolumeCamera.h"
#import "BKVecSimd.h"
#include <stdlib.h>

// The letter outlines lie a hair in front of the letters (which lie 0.001 in front of the
// faces), so the depth test never lets the letter fill flicker over its own edge.
static const double BKCubeOutlineOffset = BK_ORIENTATION_CUBE_TEXT_OFFSET + 0.0005;

@implementation BKOrientationCube
{
    BKMeshRenderer *_renderer;
    NSArray<NSString *> *_labels;
    simd_float3 _letterColors[BKCubeFaceCount];
    BKMeshObject *_cubeObject;
    NSMutableArray<BKMeshObject *> *_letterObjects;   // one per face (may hold an empty mesh)
    BKLineObject *_outlineObject;
    NSUInteger _skipped;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (device == nil) device = [BKMetalDevice preferredDevice];
    BKMeshRenderer *renderer = device ? [[BKMeshRenderer alloc] initWithDevice:device error:error] : nil;
    if (renderer == nil) {
        if (error && *error == nil)
            *error = [NSError errorWithDomain:@"BKOrientationCube" code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: @"no Metal GPU for the orientation cube" }];
        return nil;
    }
    if ((self = [super init])) {
        _renderer = renderer;
        _outlineWidth = 1;
        _showsOutlines = YES;
        for (int32_t f = 0; f < BKCubeFaceCount; f++) _letterColors[f] = BKV3fToSimd(BKOrientationCubeDefaultLetterColor(f));
        _cubeColor = BKV3fToSimd(BKOrientationCubeDefaultCubeColor());
        _outlineColor = BKV3fToSimd(BKOrientationCubeDefaultOutlineColor());
        [self buildCube];
        [self setLabels:nil];
    }
    return self;
}

- (BKMeshRenderer *)renderer { return _renderer; }
- (NSArray<NSString *> *)labels { return _labels; }
- (NSUInteger)skippedCharacterCount { return _skipped; }

// What: the white cube (lit like the classic cube: diffuse light only, no shine).
- (void)buildCube
{
    float positions[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT], normals[3 * BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT];
    uint32_t triangles[3 * BK_ORIENTATION_CUBE_BOX_TRIANGLE_COUNT];
    BKOrientationCubeFillBox(positions, normals, triangles);
    simd_float3 p[BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT], n[BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT];
    for (int i = 0; i < BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT; i++) {
        p[i] = simd_make_float3(positions[3 * i], positions[3 * i + 1], positions[3 * i + 2]);
        n[i] = simd_make_float3(normals[3 * i], normals[3 * i + 1], normals[3 * i + 2]);
    }
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:p vertexCount:BK_ORIENTATION_CUBE_BOX_VERTEX_COUNT
                                            indices:triangles indexCount:3 * BK_ORIENTATION_CUBE_BOX_TRIANGLE_COUNT
                                            normals:n colors:NULL error:NULL];
    mesh.name = @"orientation cube";
    _cubeObject = [[BKMeshObject alloc] initWithMesh:mesh];
    _cubeObject.color = _cubeColor;
    _cubeObject.usesOwnMaterial = YES;   // classic cube material: ambient 0, diffuse 1, specular 0
    _cubeObject.ambient = 0;
    _cubeObject.diffuse = 1;
    _cubeObject.specular = 0;
    _cubeObject.specularPower = 1;
    _cubeObject.useVertexColors = NO;
}

- (void)setLabels:(NSArray<NSString *> *)labels
{
    if (labels.count != BKCubeFaceCount) {
        NSMutableArray *classic = [NSMutableArray array];
        for (int32_t f = 0; f < BKCubeFaceCount; f++) [classic addObject:@(BKOrientationCubeDefaultLabel(f))];
        labels = classic;
    }
    _labels = [labels copy];
    _skipped = 0;
    _letterObjects = [NSMutableArray array];
    NSMutableData *segments = [NSMutableData data];   // simd_float3 point pairs, all faces
    for (int32_t f = 0; f < BKCubeFaceCount; f++) {
        const char *label = _labels[f].UTF8String ?: "";
        BKOrientationLabelSize size = BKOrientationCubeLabelSize(label);
        _skipped += size.skippedCount;
        float *v = calloc(MAX(size.vertexCount, 1u) * 3, sizeof(float));
        uint32_t *t = calloc(MAX(size.triangleCount, 1u) * 3, sizeof(uint32_t));
        float *s = calloc(MAX(size.segmentCount, 1u) * 6, sizeof(float));
        BKOrientationCubeFillLabel(f, label, BK_ORIENTATION_CUBE_TEXT_SCALE, BK_ORIENTATION_CUBE_TEXT_OFFSET, v, t, NULL);
        BKOrientationCubeFillLabel(f, label, BK_ORIENTATION_CUBE_TEXT_SCALE, BKCubeOutlineOffset, NULL, NULL, s);
        BKVec3d normal;
        BKOrientationCubeFaceFrame(f, &normal, NULL, NULL);
        simd_float3 *p = calloc(MAX(size.vertexCount, 1u), sizeof(simd_float3));
        simd_float3 *n = calloc(MAX(size.vertexCount, 1u), sizeof(simd_float3));
        for (uint32_t i = 0; i < size.vertexCount; i++) {
            p[i] = simd_make_float3(v[3 * i], v[3 * i + 1], v[3 * i + 2]);
            n[i] = simd_make_float3((float)normal.x, (float)normal.y, (float)normal.z);
        }
        BKMesh *mesh = size.vertexCount
            ? [[BKMesh alloc] initWithVertices:p vertexCount:size.vertexCount indices:t indexCount:3 * size.triangleCount
                                       normals:n colors:NULL error:NULL]
            : [[BKMesh alloc] init];
        mesh.name = [NSString stringWithFormat:@"orientation letter %@", _labels[f]];
        BKMeshObject *letter = [[BKMeshObject alloc] initWithMesh:mesh ?: [[BKMesh alloc] init]];
        letter.color = _letterColors[f];
        letter.lit = NO;   // classic letters: flat colour (ambient 1, diffuse 0)
        letter.useVertexColors = NO;
        letter.visible = size.vertexCount > 0;
        [_letterObjects addObject:letter];
        for (uint32_t i = 0; i < 2 * size.segmentCount; i++) {
            simd_float3 q = simd_make_float3(s[3 * i], s[3 * i + 1], s[3 * i + 2]);
            [segments appendBytes:&q length:sizeof(q)];
        }
        free(v); free(t); free(s); free(p); free(n);
    }
    NSUInteger pointCount = segments.length / sizeof(simd_float3);
    _outlineObject = pointCount ? [[BKLineObject alloc] initWithPoints:segments.bytes count:pointCount] : nil;
    _outlineObject.color = _outlineColor;
    _outlineObject.lineWidth = _outlineWidth;
    _outlineObject.visible = _showsOutlines && pointCount > 0;
    [self updateRendererObjects];
}

- (void)updateRendererObjects
{
    _renderer.objects = [@[_cubeObject] arrayByAddingObjectsFromArray:_letterObjects];
    _renderer.lineObjects = _outlineObject ? @[_outlineObject] : @[];
}

- (void)setLetterColor:(simd_float3)color forFace:(NSInteger)face
{
    if (face < 0 || face >= BKCubeFaceCount) return;
    _letterColors[face] = color;
    if ((NSUInteger)face < _letterObjects.count) _letterObjects[face].color = color;
}

- (simd_float3)letterColorForFace:(NSInteger)face
{
    return (face >= 0 && face < BKCubeFaceCount) ? _letterColors[face] : simd_make_float3(1, 1, 1);
}

- (void)setCubeColor:(simd_float3)cubeColor { _cubeColor = cubeColor; _cubeObject.color = cubeColor; }
- (void)setOutlineColor:(simd_float3)outlineColor { _outlineColor = outlineColor; _outlineObject.color = outlineColor; }
- (void)setShowsOutlines:(BOOL)shows { _showsOutlines = shows; _outlineObject.visible = shows && _outlineObject.segmentCount > 0; }
- (void)setOutlineWidth:(CGFloat)width { _outlineWidth = MAX(width, 0.1); _outlineObject.lineWidth = _outlineWidth; }

- (NSArray<BKMeshObject *> *)meshObjects { return _renderer.objects; }
- (NSArray<BKLineObject *> *)lineObjects { return _renderer.lineObjects; }

+ (BKCameraFrame)cameraFrameForVolumeCamera:(BKVolumeCamera *)camera
{
    N3Vector p = camera.position, d = camera.direction, u = camera.viewUp;
    BKCameraFrame f;
    f.position = BKV3d(p.x, p.y, p.z);
    f.direction = BKV3dNormalize(BKV3d(d.x, d.y, d.z));
    f.up = BKV3dNormalize(BKV3d(u.x, u.y, u.z));
    f.parallelScale = camera.parallelScale;
    f.viewAngle = camera.viewAngle;
    f.perspective = camera.projection == BKProjectionPerspective;
    return f;
}

- (BOOL)setMainCamera:(BKCameraFrame)mainCamera cornerAspect:(double)cornerAspect
{
    BKCameraFrame c;
    if (!BKOrientationCubeCamera(mainCamera, cornerAspect, &c)) return NO;
    _renderer.projection = BKProjectionPerspective;
    _renderer.cameraPosition = N3VectorMake(c.position.x, c.position.y, c.position.z);
    _renderer.cameraDirection = N3VectorMake(c.direction.x, c.direction.y, c.direction.z);
    _renderer.cameraUp = N3VectorMake(c.up.x, c.up.y, c.up.z);
    _renderer.fieldOfView = c.viewAngle;
    return YES;
}

// What: the drawing area the renderer will use (whole picture when viewport is empty).
static CGRect BKCubeArea(CGRect viewport, NSUInteger width, NSUInteger height)
{
    CGRect all = CGRectMake(0, 0, width, height);
    return CGRectIsEmpty(viewport) ? all : CGRectIntersection(CGRectIntegral(viewport), all);
}

- (BOOL)encodeToTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer viewport:(CGRect)viewport
             mainCamera:(BKCameraFrame)mainCamera clear:(BOOL)clear clearColor:(simd_float4)clearColor error:(NSError **)error
{
    CGRect area = BKCubeArea(viewport, target.width, target.height);
    if (area.size.width < 1 || area.size.height < 1) return NO;
    if (![self setMainCamera:mainCamera cornerAspect:area.size.width / area.size.height]) return NO;
    _renderer.viewport = viewport;
    return [_renderer encodeRenderToColorTexture:target rayDistanceTexture:nil commandBuffer:commandBuffer
                                           clear:clear clearColor:clearColor error:error];
}

- (BKRenderResult *)renderWithWidth:(NSUInteger)width height:(NSUInteger)height viewport:(CGRect)viewport
                         mainCamera:(BKCameraFrame)mainCamera error:(NSError **)error
{
    CGRect area = BKCubeArea(viewport, width, height);
    if (area.size.width < 1 || area.size.height < 1) return nil;
    if (![self setMainCamera:mainCamera cornerAspect:area.size.width / area.size.height]) return nil;
    _renderer.viewport = viewport;
    return [_renderer renderWithWidth:width height:height error:error];
}

@end
