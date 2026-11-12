// Tests for BKMeshRenderer (Metal mesh drawing). They run on the real GPU and skip
// themselves on a machine without one.
//
// What is checked, in plain terms:
//  - a box at a known patient position appears exactly where it should on screen from
//    all six standard views (front, back, left, right, top, bottom), using the view
//    conventions written out by hand below (e.g. front view: the patient's left is on
//    the image's right, like looking at a patient facing you);
//  - a sphere drawn as a MESH and the same sphere drawn as a CT VOLUME by
//    BKVolumeRenderer, with the same BKVolumeCamera, land on the same pixels (both
//    projections, all standard views): meshes and volume line up in patient mm;
//  - nearer surfaces hide farther ones; see-through objects blend; vertex colours,
//    hiding, moving objects and editing meshes work; the ray-distance output is right.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitMeshRender.h"
#import "BorosKitMesh.h"
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

// What a mask of covered pixels looks like: count and centre (pixel coordinates).
typedef struct {
    NSUInteger count;
    double cx, cy;
} BKCoverage;

// What: pixels whose opacity is above half, their number and centre.
static BKCoverage BKCoverageOf(BKRenderResult *result)
{
    BKCoverage c = {0, 0, 0};
    const uint8_t *rgba = result.rgba8Data.bytes;
    for (NSUInteger y = 0; y < result.height; y++)
        for (NSUInteger x = 0; x < result.width; x++)
            if (rgba[4 * (y * result.width + x) + 3] > 127) { c.count++; c.cx += x; c.cy += y; }
    if (c.count) { c.cx /= c.count; c.cy /= c.count; }
    return c;
}

@interface BKMeshRendererTests : XCTestCase
@end

@implementation BKMeshRendererTests

- (BKMeshRenderer *)renderer
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return nil; }
    NSError *error = nil;
    BKMeshRenderer *r = [[BKMeshRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);
    return r;
}

- (BKRenderResult *)render:(BKMeshRenderer *)r size:(NSUInteger)size
{
    NSError *error = nil;
    BKRenderResult *result = [r renderWithWidth:size height:size error:&error];
    XCTAssertNotNil(result, @"%@", error);
    return result;
}

- (BOOL)isCoveredAtX:(NSUInteger)x y:(NSUInteger)y in:(BKRenderResult *)result
{
    uint8_t px[4];
    [result getRGBA8:px atX:x y:y];
    return px[3] > 127;
}

#pragma mark - Basics

- (void)testUniformLayoutMatchesGPU
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    XCTAssertEqual([r gpuUniformBlockSize], [BKMeshRenderer cpuUniformBlockSize]);
}

- (void)testNothingToDraw
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    BKRenderResult *result = [self render:r size:16];
    XCTAssertEqual(BKCoverageOf(result).count, 0u);
    XCTAssertTrue(isinf([result valueAtX:8 y:8]));
    NSError *error = nil;
    XCTAssertNil([r renderWithWidth:0 height:10 error:&error]);
    XCTAssertNotNil(error);
    r.cameraUp = r.cameraDirection;   // impossible camera
    error = nil;
    XCTAssertNil([r renderWithWidth:10 height:10 error:&error]);
    XCTAssertNotNil(error);
}

#pragma mark - Placement in patient mm

// Hand-written screen axes of the standard views (where the patient's directions end
// up on screen). Written out independently of the renderer on purpose:
//   Anterior : camera in front, head up       -> patient's left (+x) on screen right
//   Posterior: camera behind, head up         -> patient's left on screen left
//   Left     : camera at patient's left       -> patient's back (+y) on screen right
//   Right    : camera at patient's right      -> patient's front (-y) on screen right
//   Superior : camera above the head, anterior up -> patient's right (-x) on screen right
//   Inferior : camera at the feet, anterior up    -> patient's left (+x) on screen right
static void BKExpectedAxes(BKStandardView view, simd_float3 *right, simd_float3 *up)
{
    switch (view) {
        case BKStandardViewAnterior:  *right = simd_make_float3(1, 0, 0);  *up = simd_make_float3(0, 0, 1); break;
        case BKStandardViewPosterior: *right = simd_make_float3(-1, 0, 0); *up = simd_make_float3(0, 0, 1); break;
        case BKStandardViewLeft:      *right = simd_make_float3(0, 1, 0);  *up = simd_make_float3(0, 0, 1); break;
        case BKStandardViewRight:     *right = simd_make_float3(0, -1, 0); *up = simd_make_float3(0, 0, 1); break;
        case BKStandardViewSuperior:  *right = simd_make_float3(-1, 0, 0); *up = simd_make_float3(0, -1, 0); break;
        case BKStandardViewInferior:  *right = simd_make_float3(1, 0, 0);  *up = simd_make_float3(0, -1, 0); break;
    }
}

// A 10 mm box centred at (20, -15, 30) mm, camera centred on (0,0,0) showing 100 mm in
// 100 pixels (1 mm per pixel). The box must cover exactly the 10 x 10 pixels around
// where the hand-written axes put its centre, from every standard view.
- (void)testBoxAppearsAtExpectedPixelsFromStandardViews
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    simd_float3 centre = simd_make_float3(20, -15, 30);
    BKMeshObject *box = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:centre - 5 max:centre + 5]];
    r.objects = @[box];
    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    camera.focalPoint = N3VectorZero;
    camera.parallelScale = 50;
    for (BKStandardView view = BKStandardViewAnterior; view <= BKStandardViewInferior; view++) {
        [camera showStandardView:view];
        [r setCameraFromVolumeCamera:camera aspectRatio:1];
        BKRenderResult *result = [self render:r size:100];
        simd_float3 right, up;
        BKExpectedAxes(view, &right, &up);
        // Pixel centres: x = 50 + mm to the right - 0.5, y = 50 - mm up - 0.5 (rows top first).
        double ex = 50 + simd_dot(centre, right) - 0.5, ey = 50 - simd_dot(centre, up) - 0.5;
        BKCoverage c = BKCoverageOf(result);
        XCTAssertEqual(c.count, 100u, @"view %ld", (long)view);
        XCTAssertEqualWithAccuracy(c.cx, ex, 0.01, @"view %ld", (long)view);
        XCTAssertEqualWithAccuracy(c.cy, ey, 0.01, @"view %ld", (long)view);
    }
    // Spelled out once for the front view: box centre 20 mm to the patient's left and
    // 30 mm up -> right of centre and above centre; its mirror image is empty.
    [camera showStandardView:BKStandardViewAnterior];
    [r setCameraFromVolumeCamera:camera aspectRatio:1];
    BKRenderResult *front = [self render:r size:100];
    XCTAssertTrue([self isCoveredAtX:70 y:20 in:front]);
    XCTAssertFalse([self isCoveredAtX:30 y:20 in:front]);
    XCTAssertFalse([self isCoveredAtX:70 y:80 in:front]);
}

// A sphere of radius 9 mm at (10, -6, 4) mm, once as a CT volume (64 mm cube of 1 mm
// voxels starting at (-32,-32,-32)) and once as a mesh. Same BKVolumeCamera for both.
// The two pictures must cover the same pixels: same centre (within half a pixel) and
// nearly the same area (the voxel version is slightly blocky).
- (void)testMeshLinesUpWithVolume
{
    BKMeshRenderer *meshRenderer = [self renderer];
    if (!meshRenderer) return;
    const NSUInteger n = 64;
    const simd_float3 centre = simd_make_float3(10, -6, 4);
    const float radius = 9;
    float *voxels = malloc(sizeof(float) * n * n * n);
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger y = 0; y < n; y++)
            for (NSUInteger x = 0; x < n; x++) {
                simd_float3 p = simd_make_float3(-32.0f + x, -32.0f + y, -32.0f + z);
                voxels[(z * n + y) * n + x] = simd_distance(p, centre) <= radius ? 1000.0f : -1000.0f;
            }
    double orientation[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    CPRVolumeData *volume = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:voxels pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                                      origin:N3VectorMake(-32, -32, -32) orientation:orientation
                                                                    spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
    NSError *error = nil;
    BKVolumeRenderer *volumeRenderer = [[BKVolumeRenderer alloc] initWithDevice:meshRenderer.device error:&error];
    XCTAssertTrue([volumeRenderer setVolumeData:volume error:&error], @"%@", error);
    volumeRenderer.sampleSpacing = 0.25;
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];   // bone opaque, air invisible
    [tf addColorPointAtValue:-1000 red:1 green:1 blue:1];
    [tf addColorPointAtValue:1000 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:-1000 opacity:0];
    [tf addOpacityPointAtValue:-1 opacity:0];
    [tf addOpacityPointAtValue:1 opacity:1];
    [tf addOpacityPointAtValue:1000 opacity:1];
    volumeRenderer.transferFunction = tf;
    meshRenderer.objects = @[[[BKMeshObject alloc] initWithMesh:[BKMesh sphereMeshWithCenter:centre radius:radius subdivisions:5]]];

    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    for (NSNumber *projection in @[@(BKProjectionOrthographic), @(BKProjectionPerspective)]) {
        camera.projection = projection.intValue;
        [camera resetToBoxMin:N3VectorMake(-32, -32, -32) max:N3VectorMake(31, 31, 31)];
        for (BKStandardView view = BKStandardViewAnterior; view <= BKStandardViewInferior; view++) {
            [camera showStandardView:view];
            [camera applyToRenderer:volumeRenderer aspectRatio:1];
            [meshRenderer setCameraFromVolumeCamera:camera aspectRatio:1];
            BKRenderResult *v = [volumeRenderer renderWithWidth:128 height:128 error:&error];
            BKRenderResult *m = [self render:meshRenderer size:128];
            BKCoverage cv = BKCoverageOf(v), cm = BKCoverageOf(m);
            XCTAssertGreaterThan(cm.count, 200u);
            XCTAssertEqualWithAccuracy(cm.cx, cv.cx, 0.5, @"projection %@ view %ld", projection, (long)view);
            XCTAssertEqualWithAccuracy(cm.cy, cv.cy, 0.5, @"projection %@ view %ld", projection, (long)view);
            XCTAssertEqualWithAccuracy((double)cm.count, (double)cv.count, 0.06 * cv.count, @"projection %@ view %ld", projection, (long)view);
        }
    }
    // The renderer-to-renderer shortcut gives the same picture.
    [camera showStandardView:BKStandardViewLeft];
    [camera applyToRenderer:volumeRenderer aspectRatio:1];
    [meshRenderer setCameraFromVolumeCamera:camera aspectRatio:1];
    NSData *a = [self render:meshRenderer size:64].rgba8Data;
    [meshRenderer copyCameraFromVolumeRenderer:volumeRenderer];
    XCTAssertEqualObjects([self render:meshRenderer size:64].rgba8Data, a);
}

#pragma mark - Depth, transparency, colour

// Two boxes on the line of sight: the nearer one is seen, whatever the drawing order.
// The ray distance is the distance from the image plane to the near box's front face.
- (void)testNearerSurfaceWinsAndRayDistance
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    // Front view: the camera looks along +y, so smaller y = nearer.
    BKMeshObject *nearBox = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-10, -20, -10) max:simd_make_float3(10, -10, 10)]];
    BKMeshObject *farBox = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-20, 10, -20) max:simd_make_float3(20, 20, 20)]];
    nearBox.color = simd_make_float3(1, 0, 0);
    farBox.color = simd_make_float3(0, 0, 1);
    r.cameraPosition = N3VectorMake(0, -40, 0);
    r.specular = 0;   // no white highlight, so the colours stay pure
    for (NSArray *order in @[@[nearBox, farBox], @[farBox, nearBox]]) {
        r.objects = order;
        BKRenderResult *result = [self render:r size:100];
        uint8_t px[4];
        [result getRGBA8:px atX:50 y:50];
        XCTAssertGreaterThan(px[0], 200);   // red: the near box
        XCTAssertEqual(px[2], 0);
        // Face at y = -20, image plane at y = -40: 20 mm along the ray.
        XCTAssertEqualWithAccuracy([result valueAtX:50 y:50], 20.0f, 1e-3);
        [result getRGBA8:px atX:50 y:35];   // above the near box: the far box
        XCTAssertGreaterThan(px[2], 200);
        XCTAssertEqualWithAccuracy([result valueAtX:50 y:35], 50.0f, 1e-3);
        XCTAssertTrue(isinf([result valueAtX:2 y:2]));
    }
    // Perspective: distance from the eye along the ray.
    r.projection = BKProjectionPerspective;
    r.cameraPosition = N3VectorMake(0, -100, 0);
    r.objects = @[nearBox];
    XCTAssertEqualWithAccuracy([[self render:r size:101] valueAtX:50 y:50], 80.0f, 1e-3);
}

// Lighting like the volume: a face looking straight at the viewer gets
// ambient + diffuse + specular = 0.2 + 0.8 + 0.2 (clamped to 1) times the colour;
// a see-through box over a solid one blends.
- (void)testLightingAndTransparency
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    BKMeshObject *back = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-30, 10, -30) max:simd_make_float3(30, 20, 30)]];
    back.color = simd_make_float3(0, 0, 0.5f);
    r.objects = @[back];
    r.specular = 0;
    uint8_t px[4];
    [[self render:r size:100] getRGBA8:px atX:50 y:50];
    XCTAssertEqualWithAccuracy(px[2], 128, 1);   // 0.5 * (0.2 + 0.8)
    r.ambient = 0.5f; r.diffuse = 0;              // light from the side would not matter now
    [[self render:r size:100] getRGBA8:px atX:50 y:50];
    XCTAssertEqualWithAccuracy(px[2], 64, 1);

    r.ambient = 0.2f; r.diffuse = 0.8f;
    BKMeshObject *glass = [[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-10, -20, -10) max:simd_make_float3(10, -10, 10)]];
    glass.color = simd_make_float3(1, 0, 0);
    glass.opacity = 0.5f;
    r.objects = @[glass, back];   // see-through listed first: must still be drawn last
    BKRenderResult *result = [self render:r size:100];
    [result getRGBA8:px atX:50 y:50];
    // Two see-through faces (front and back of the glass box) over the blue wall.
    XCTAssertGreaterThan(px[0], 100);
    XCTAssertGreaterThan(px[2], 10);
    XCTAssertEqual(px[3], 255);
    // The see-through box does not stop the ray: the distance is the wall's.
    XCTAssertEqualWithAccuracy([result valueAtX:50 y:50], 10.0f, 1e-3);

    // Hidden and fully transparent objects are not drawn.
    glass.visible = NO;
    back.opacity = 0;
    XCTAssertEqual(BKCoverageOf([self render:r size:32]).count, 0u);
}

- (void)testVertexColours
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    BKMesh *mesh = [BKMesh boxMeshWithMin:simd_make_float3(-10, -10, -10) max:simd_make_float3(10, 10, 10)];
    simd_float4 green[8];
    for (int i = 0; i < 8; i++) green[i] = simd_make_float4(0, 1, 0, 1);
    [mesh setColors:green];
    BKMeshObject *object = [[BKMeshObject alloc] initWithMesh:mesh];
    object.color = simd_make_float3(1, 1, 1);
    r.objects = @[object];
    r.specular = 0;
    uint8_t px[4];
    [[self render:r size:64] getRGBA8:px atX:32 y:32];
    XCTAssertEqual(px[0], 0);
    XCTAssertGreaterThan(px[1], 250);
    object.useVertexColors = NO;
    [[self render:r size:64] getRGBA8:px atX:32 y:32];
    XCTAssertGreaterThan(px[0], 250);
}

#pragma mark - Moving and editing

// Moving the object (its placement matrix) or editing the mesh in place both show up
// in the next picture (the renderer re-uploads edited meshes by itself).
- (void)testMovingAndEditingObjects
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    BKMesh *mesh = [BKMesh boxMeshWithMin:simd_make_float3(-5, -5, -5) max:simd_make_float3(5, 5, 5)];
    BKMeshObject *object = [[BKMeshObject alloc] initWithMesh:mesh];
    r.objects = @[object];
    BKCoverage c = BKCoverageOf([self render:r size:100]);
    XCTAssertEqualWithAccuracy(c.cx, 49.5, 0.01);
    // Placement: 20 mm to the patient's left = 20 pixels to the right in the front view.
    object.transform = simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                                   simd_make_float4(0, 0, 1, 0), simd_make_float4(20, 0, 0, 1));
    c = BKCoverageOf([self render:r size:100]);
    XCTAssertEqualWithAccuracy(c.cx, 69.5, 0.01);
    // Edit the mesh itself: 10 mm up = 10 pixels up.
    [mesh transformByMatrix:simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                                        simd_make_float4(0, 0, 1, 0), simd_make_float4(0, 0, 10, 1))];
    c = BKCoverageOf([self render:r size:100]);
    XCTAssertEqualWithAccuracy(c.cx, 69.5, 0.01);
    XCTAssertEqualWithAccuracy(c.cy, 39.5, 0.01);
    XCTAssertEqual(c.count, 100u);
}

// Drawing over an existing picture (clear:NO) keeps it where there is no mesh, e.g.
// meshes laid over a volume image.
- (void)testDrawOverExistingImage
{
    BKMeshRenderer *r = [self renderer];
    if (!r) return;
    r.objects = @[[[BKMeshObject alloc] initWithMesh:[BKMesh boxMeshWithMin:simd_make_float3(-5, -5, -5) max:simd_make_float3(5, 5, 5)]]];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
#if TARGET_OS_OSX
    if (!r.device.hasUnifiedMemory) d.storageMode = MTLStorageModeManaged;
#endif
    id<MTLTexture> target = [r.device newTextureWithDescriptor:d];
    uint8_t purple[32 * 32 * 4];
    for (int i = 0; i < 32 * 32; i++) { purple[4 * i] = 200; purple[4 * i + 1] = 0; purple[4 * i + 2] = 100; purple[4 * i + 3] = 255; }
    [target replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:purple bytesPerRow:32 * 4];
    id<MTLCommandBuffer> cb = [r.commandQueue commandBuffer];
    NSError *error = nil;
    XCTAssertTrue([r encodeRenderToColorTexture:target rayDistanceTexture:nil commandBuffer:cb clear:NO
                                     clearColor:simd_make_float4(0, 0, 0, 0) error:&error], @"%@", error);
#if TARGET_OS_OSX
    if (target.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
    }
#endif
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t out[32 * 32 * 4];
    [target getBytes:out bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
    XCTAssertEqual(out[0], 200);                         // corner: the old picture (B of BGRA)
    XCTAssertEqual(out[2], 100);
    uint8_t *centre = out + 4 * (16 * 32 + 16);
    XCTAssertGreaterThan(centre[1], 200);                // centre: the bone-coloured box
}

@end
