// Tests for the interactive 3D layer: BKVolumeCamera (pure math), the adaptive quality
// controller (pure functions), BKVolumeScene (LOD switching, WL/WW) and the GPU
// texture output of BKVolumeRenderer (matches the synchronous output; shading, crop
// and clipping behave). GPU tests skip themselves when no Metal device exists.
//
// Test volume (GPU tests): 64^3 voxels of 1 mm, origin 0, identity orientation; a
// sphere of radius 10 voxels at (31, 31, 31) with value 1000, background -1000.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

static const NSUInteger kN = 64;

// What: compares two vectors within a tolerance (XCTest has no N3Vector assert).
static BOOL BKVectorsClose(N3Vector a, N3Vector b, CGFloat tol)
{
    return fabs(a.x - b.x) <= tol && fabs(a.y - b.y) <= tol && fabs(a.z - b.z) <= tol;
}

@interface BKVolumeSceneTests : XCTestCase
@end

@implementation BKVolumeSceneTests

#pragma mark - Helpers

// What: the sphere volume described at the top. Why: known geometry for GPU checks.
- (CPRVolumeData *)sphereVolume
{
    float *bytes = malloc(sizeof(float) * kN * kN * kN);
    for (NSUInteger z = 0; z < kN; z++)
        for (NSUInteger y = 0; y < kN; y++)
            for (NSUInteger x = 0; x < kN; x++) {
                double dx = (double)x - 31, dy = (double)y - 31, dz = (double)z - 31;
                bytes[(z * kN + y) * kN + x] = (dx * dx + dy * dy + dz * dz <= 100.0) ? 1000.0f : -1000.0f;
            }
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    return [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:kN pixelsHigh:kN pixelsDeep:kN
                                                     origin:N3VectorZero orientation:orientation
                                                   spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
}

// What: a renderer with the sphere loaded and an orthographic camera looking along +z,
// 64 mm wide, centred on the volume. Skips the test without a GPU.
- (BKVolumeRenderer *)sphereRenderer
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return nil; }
    NSError *error = nil;
    BKVolumeRenderer *r = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(r, @"%@", error);
    XCTAssertTrue([r setVolumeData:[self sphereVolume] error:&error], @"%@", error);
    r.projection = BKProjectionOrthographic;
    r.cameraPosition = N3VectorMake(31.5, 31.5, 31.5);
    r.cameraDirection = N3VectorMake(0, 0, 1);
    r.cameraUp = N3VectorMake(0, 1, 0);
    r.viewWidth = r.viewHeight = 64;
    r.sampleSpacing = 0.5;
    // Composite look: everything above 0 HU opaque white, below transparent.
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-1000 red:1 green:1 blue:1];
    [tf addColorPointAtValue:1000 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:-1000 opacity:0];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:10 opacity:1];
    [tf addOpacityPointAtValue:1000 opacity:1];
    r.transferFunction = tf;
    return r;
}

// What: a CPU-readable RGBA8 texture usable as a compute target.
// Why: tests read back what the on-screen path would have shown.
- (id<MTLTexture>)targetTextureForDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h
{
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:w height:h mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModeShared;
#if TARGET_OS_OSX
    if (!device.hasUnifiedMemory) desc.storageMode = MTLStorageModeManaged;   // Intel Macs
#endif
    return [device newTextureWithDescriptor:desc];
}

// What: commits, waits, and copies a texture's RGBA bytes. Why: compare with buffers.
- (NSData *)finishAndReadTexture:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)cb
{
#if TARGET_OS_OSX
    if (texture.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:texture];
        [blit endEncoding];
    }
#endif
    [cb commit];
    [cb waitUntilCompleted];
    XCTAssertNotEqual(cb.status, MTLCommandBufferStatusError, @"%@", cb.error);
    NSMutableData *data = [NSMutableData dataWithLength:texture.width * texture.height * 4];
    [texture getBytes:data.mutableBytes bytesPerRow:texture.width * 4
           fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
    return data;
}

// What: renders through the GPU-texture path (black background) and reads it back.
- (NSData *)renderTextureWith:(BKVolumeRenderer *)r
{
    id<MTLTexture> tex = [self targetTextureForDevice:r.device width:kN height:kN];
    id<MTLCommandBuffer> cb = [r.commandQueue commandBuffer];
    NSError *error = nil;
    XCTAssertTrue([r encodeRenderToTexture:tex commandBuffer:cb backgroundColor:simd_make_float4(0, 0, 0, 1) error:&error], @"%@", error);
    return [self finishAndReadTexture:tex commandBuffer:cb];
}

// What: red channel of pixel (x, y) in an RGBA8 buffer.
static uint8_t BKRed(NSData *rgba, NSUInteger width, NSUInteger x, NSUInteger y)
{
    return ((const uint8_t *)rgba.bytes)[4 * (y * width + x)];
}

#pragma mark - Camera math

// What: each standard view has the documented direction/up, and the Horos-matching
// ones put the patient's left on the image's right in the anterior view.
- (void)testStandardViewDirections
{
    N3Vector d, u;
    [BKVolumeCamera getStandardView:BKStandardViewAnterior direction:&d viewUp:&u];
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(0, 1, 0), 1e-9));
    XCTAssertTrue(BKVectorsClose(u, N3VectorMake(0, 0, 1), 1e-9));
    // right = cross(direction, up) = +x = patient's left: shown on the right, as in a
    // radiograph viewed from the front.
    XCTAssertTrue(BKVectorsClose(N3VectorCrossProduct(d, u), N3VectorMake(1, 0, 0), 1e-9));

    [BKVolumeCamera getStandardView:BKStandardViewLeft direction:&d viewUp:&u];      // Horos saView
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(-1, 0, 0), 1e-9));
    XCTAssertTrue(BKVectorsClose(u, N3VectorMake(0, 0, 1), 1e-9));
    [BKVolumeCamera getStandardView:BKStandardViewRight direction:&d viewUp:&u];     // saViewOpposite
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(1, 0, 0), 1e-9));
    [BKVolumeCamera getStandardView:BKStandardViewInferior direction:&d viewUp:&u];  // axView
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(0, 0, 1), 1e-9));
    XCTAssertTrue(BKVectorsClose(u, N3VectorMake(0, -1, 0), 1e-9));
    [BKVolumeCamera getStandardView:BKStandardViewSuperior direction:&d viewUp:&u];
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(0, 0, -1), 1e-9));
    [BKVolumeCamera getStandardView:BKStandardViewPosterior direction:&d viewUp:&u];
    XCTAssertTrue(BKVectorsClose(d, N3VectorMake(0, -1, 0), 1e-9));

    // Switching views keeps focal point, distance and zoom (Horos "apply the same zoom").
    BKVolumeCamera *cam = [[BKVolumeCamera alloc] init];
    cam.focalPoint = N3VectorMake(1, 2, 3);
    cam.parallelScale = 42;
    cam.distance = 123;
    [cam showStandardView:BKStandardViewInferior];
    XCTAssertTrue(BKVectorsClose(cam.focalPoint, N3VectorMake(1, 2, 3), 1e-9));
    XCTAssertEqualWithAccuracy(cam.parallelScale, 42, 1e-9);
    XCTAssertEqualWithAccuracy(cam.distance, 123, 1e-9);
}

// What: rotations undo themselves and keep the frame orthonormal.
- (void)testRotationRoundTrips
{
    BKVolumeCamera *cam = [[BKVolumeCamera alloc] init];
    N3Vector d0 = cam.direction, u0 = cam.viewUp;

    [cam azimuth:360];
    XCTAssertTrue(BKVectorsClose(cam.direction, d0, 1e-9));
    [cam azimuth:37]; [cam azimuth:-37];
    XCTAssertTrue(BKVectorsClose(cam.direction, d0, 1e-9));
    [cam elevation:25]; [cam elevation:-25];
    XCTAssertTrue(BKVectorsClose(cam.direction, d0, 1e-9));
    XCTAssertTrue(BKVectorsClose(cam.viewUp, u0, 1e-9));
    [cam roll:15]; [cam roll:-15];
    XCTAssertTrue(BKVectorsClose(cam.viewUp, u0, 1e-9));

    // Elevation over the pole must not degenerate (Horos' VTK elevation does).
    [cam elevation:90];
    XCTAssertEqualWithAccuracy(N3VectorLength(cam.viewUp), 1.0, 1e-9);
    XCTAssertEqualWithAccuracy(N3VectorDotProduct(cam.direction, cam.viewUp), 0.0, 1e-9);

    // Trackball: a drag and the opposite drag (separately) return; azimuth goes first so
    // undo in reverse order: rotate x then -x, y then -y.
    cam = [[BKVolumeCamera alloc] init];
    [cam rotateByViewDelta:CGSizeMake(50, 0) viewSize:CGSizeMake(400, 300)];
    XCTAssertEqualWithAccuracy(acos(N3VectorDotProduct(cam.direction, d0)) * 180 / M_PI, 25.0, 1e-6); // 200 * 50/400
    [cam rotateByViewDelta:CGSizeMake(-50, 0) viewSize:CGSizeMake(400, 300)];
    XCTAssertTrue(BKVectorsClose(cam.direction, d0, 1e-9));

    // Many random-ish moves keep the frame orthonormal.
    for (int i = 0; i < 200; i++) {
        [cam rotateByViewDelta:CGSizeMake(7 * sin(i), 5 * cos(i * 1.3)) viewSize:CGSizeMake(500, 400)];
        [cam roll:3 * sin(i * 0.7)];
    }
    XCTAssertEqualWithAccuracy(N3VectorLength(cam.direction), 1.0, 1e-9);
    XCTAssertEqualWithAccuracy(N3VectorLength(cam.viewUp), 1.0, 1e-9);
    XCTAssertEqualWithAccuracy(N3VectorDotProduct(cam.direction, cam.viewUp), 0.0, 1e-9);
}

// What: pan follows the pointer in mm and undoes itself; zoom undoes itself.
- (void)testPanAndZoomRoundTrips
{
    BKVolumeCamera *cam = [[BKVolumeCamera alloc] init];   // anterior, ortho, parallelScale 50
    CGSize view = CGSizeMake(400, 200);
    CGFloat mm = [cam millimetresPerViewPointForViewHeight:200];
    XCTAssertEqualWithAccuracy(mm, 0.5, 1e-12);             // 100 mm over 200 points

    [cam panByViewDelta:CGSizeMake(10, 20) viewSize:view];
    // Drag right -> camera moves to its left (-x); drag down -> camera moves up (+z).
    XCTAssertTrue(BKVectorsClose(cam.focalPoint, N3VectorMake(-5, 0, 10), 1e-9));
    [cam panByViewDelta:CGSizeMake(-10, -20) viewSize:view];
    XCTAssertTrue(BKVectorsClose(cam.focalPoint, N3VectorZero, 1e-9));

    [cam zoomByFactor:2];
    XCTAssertEqualWithAccuracy(cam.parallelScale, 25, 1e-9);
    [cam zoomByFactor:0.5];
    XCTAssertEqualWithAccuracy(cam.parallelScale, 50, 1e-9);

    cam.projection = BKProjectionPerspective;
    CGFloat d0 = cam.distance;
    [cam zoomByFactor:1.25]; [cam zoomByFactor:0.8];
    XCTAssertEqualWithAccuracy(cam.distance, d0, 1e-9);

    // Reset fits a box: focal point at its centre, parallel scale = bounding radius.
    [cam resetToBoxMin:N3VectorMake(0, 0, 0) max:N3VectorMake(30, 40, 0)];
    XCTAssertTrue(BKVectorsClose(cam.focalPoint, N3VectorMake(15, 20, 0), 1e-9));
    XCTAssertEqualWithAccuracy(cam.parallelScale, 25, 1e-9);
    XCTAssertEqualWithAccuracy(cam.distance, 25 / sin(15 * M_PI / 180), 1e-9);
}

#pragma mark - Adaptive quality controller

// What: the pure decision functions choose levels as documented.
- (void)testQualityControllerDecisions
{
    BKQualityLevel L[] = {{1, 1}, {0.75f, 1}, {0.5f, 1}, {0.5f, 2}, {0.35f, 2}};
    NSInteger n = 5;
    double budget = 0.016;

    // Start of an interaction.
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 0, budget), 0);       // unknown -> full
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 0.010, budget), 0);   // full fits
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 0.016, budget), 0);   // exactly fits
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 0.025, budget), 1);   // 25 * 0.5625 = 14.1 ms
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 0.030, budget), 2);   // 16.9 ms > budget, 7.5 ms fits
    XCTAssertEqual(BKInitialInteractiveQualityLevel(L, n, 5.0, budget), 4);     // nothing fits -> coarsest

    // During an interaction: over budget -> one step coarser, capped at the last level.
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 0, 0.020, budget), 1);
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 1, 0.050, budget), 2);   // one step, not a jump
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 4, 0.050, budget), 4);
    // Within budget at full quality -> stay.
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 0, 0.010, budget), 0);
    // Comfortably under: level 2 at 2 ms -> full estimate 8 ms -> level 1 = 4.5 ms <= 12.8 -> step up.
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 2, 0.002, budget), 1);
    // Under budget but no room: level 2 at 7 ms -> full 28 ms -> level 1 = 15.75 ms > 12.8 -> stay.
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 2, 0.007, budget), 2);
    // Unknown time / bad inputs -> no change, level clamped into range.
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 3, 0, budget), 3);
    XCTAssertEqual(BKNextInteractiveQualityLevel(L, n, 9, 0, budget), 4);

    // Costs: pixels x samples.
    XCTAssertEqualWithAccuracy(BKQualityLevelRelativeCost(L[2]), 0.25f, 1e-6);
    XCTAssertEqualWithAccuracy(BKQualityLevelRelativeCost(L[3]), 0.125f, 1e-6);
}

// What: the scene switches levels from recorded frame times and returns to full
// quality when the interaction ends (no GPU needed for the bookkeeping).
- (void)testSceneLODSwitching
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:NULL];
    XCTAssertNotNil(scene);
    scene.targetInteractiveFrameTime = 0.016;

    // A fast GPU: full quality fits, so rotating keeps full quality.
    [scene recordFrameTime:0.008 atQualityLevel:0];
    [scene beginInteraction];
    [scene recordFrameTime:0.009 atQualityLevel:0];
    XCTAssertEqual([self nextLevelOf:scene], 0);
    [scene endInteraction];

    // A slow GPU: the full-quality frame took 40 ms -> start coarser (40*0.25 = 10 ms).
    [scene recordFrameTime:0.040 atQualityLevel:0];
    [scene beginInteraction];
    XCTAssertEqual([self nextLevelOf:scene], 2);
    [scene recordFrameTime:0.020 atQualityLevel:2];     // still too slow -> one step down
    XCTAssertEqual([self nextLevelOf:scene], 3);
    [scene recordFrameTime:0.003 atQualityLevel:3];     // lots of room -> one step up
    XCTAssertEqual([self nextLevelOf:scene], 2);
    [scene endInteraction];
    XCTAssertEqual([self nextLevelOf:scene], 0);         // always full quality when idle

    // Render sizes per level.
    CGSize s = [scene renderSizeForTargetSize:CGSizeMake(800, 600) qualityLevel:2];
    XCTAssertEqual(s.width, 400); XCTAssertEqual(s.height, 300);
    s = [scene renderSizeForTargetSize:CGSizeMake(800, 600) qualityLevel:0];
    XCTAssertEqual(s.width, 800); XCTAssertEqual(s.height, 600);
}

// What: the level the scene will use for its next frame, read by encoding a frame
// into a tiny texture and checking currentQualityLevel (the documented debug output).
- (NSInteger)nextLevelOf:(BKVolumeScene *)scene
{
    if (!scene.volumeTexture) {
        NSError *error = nil;
        XCTAssertTrue([scene setVolumeData:[self sphereVolume] error:&error], @"%@", error);
    }
    id<MTLTexture> tex = [self targetTextureForDevice:scene.renderer.device width:16 height:16];
    id<MTLCommandBuffer> cb = [scene.renderer.commandQueue commandBuffer];
    XCTAssertTrue([scene encodeFrameToTexture:tex commandBuffer:cb error:NULL]);
    // Do not let this probe frame's own GPU time disturb the controller under test.
    NSInteger level = scene.currentQualityLevel;
    [cb commit];
    [cb waitUntilCompleted];
    return level;
}

#pragma mark - GPU output

// What: the texture path writes the same pixels as the synchronous buffer path.
- (void)testTextureOutputMatchesSynchronousOutput
{
    BKVolumeRenderer *r = [self sphereRenderer];
    if (!r) return;
    NSError *error = nil;
    for (NSNumber *mode in @[@(BKRenderModeMIP), @(BKRenderModeComposite)]) {
        r.mode = (BKRenderMode)mode.intValue;
        r.windowCenter = 0; r.windowWidth = 2000;
        BKRenderResult *sync = [r renderWithWidth:kN height:kN error:&error];
        XCTAssertNotNil(sync, @"%@", error);
        NSData *tex = [self renderTextureWith:r];
        const uint8_t *a = sync.rgba8Data.bytes, *b = tex.bytes;
        NSUInteger maxDiff = 0;
        for (NSUInteger i = 0; i < kN * kN; i++)
            for (int c = 0; c < 3; c++)   // RGB; the texture is opaque (alpha 1)
                maxDiff = MAX(maxDiff, (NSUInteger)abs((int)a[4 * i + c] - (int)b[4 * i + c]));
        // Composite over black = premultiplied colour; allow 1 for 8-bit rounding.
        XCTAssertLessThanOrEqual(maxDiff, 1u, @"mode %@", mode);
    }
}

// What: with lighting, the sphere's centre (facing the viewer and the head-light) is
// brighter than a point near its edge (surface turned away).
- (void)testShadingLightsTheFacingSide
{
    BKVolumeRenderer *r = [self sphereRenderer];
    if (!r) return;
    r.mode = BKRenderModeComposite;
    r.shadingEnabled = YES;
    r.ambient = 0.1f; r.diffuse = 0.9f; r.specular = 0; r.specularPower = 1;
    NSData *img = [self renderTextureWith:r];
    // Pixel (32, 32) looks at the sphere's centre; (32 + 9, 32) is ~9 mm off-centre.
    uint8_t centre = BKRed(img, kN, 32, 32), edge = BKRed(img, kN, 41, 32);
    XCTAssertGreaterThan(centre, 200);
    XCTAssertGreaterThan(edge, 0);
    XCTAssertGreaterThan(centre, edge + 60, @"centre %u edge %u", centre, edge);

    // Without lighting both are the same flat white.
    r.shadingEnabled = NO;
    img = [self renderTextureWith:r];
    XCTAssertEqual(BKRed(img, kN, 32, 32), BKRed(img, kN, 41, 32));
}

// What: a crop box keeping x <= 31 removes the other half of the sphere, and a
// clipping plane does the same in patient space.
- (void)testCropAndClipRemoveHalf
{
    BKVolumeRenderer *r = [self sphereRenderer];
    if (!r) return;
    r.mode = BKRenderModeMIP;
    r.windowCenter = 0; r.windowWidth = 2000;
    // Camera right = cross(+z, +y) = -x, so image x = 63 - voxel x (see the renderer tests):
    // voxel x 24 -> image column 39 (left of centre: kept by crop x <= 31),
    // voxel x 38 -> image column 25 (cut away).
    NSData *full = [self renderTextureWith:r];
    XCTAssertGreaterThan(BKRed(full, kN, 39, 32), 200);
    XCTAssertGreaterThan(BKRed(full, kN, 25, 32), 200);

    r.cropMin = N3VectorMake(0, 0, 0);
    r.cropMax = N3VectorMake(31, 63, 63);
    NSData *cropped = [self renderTextureWith:r];
    XCTAssertGreaterThan(BKRed(cropped, kN, 39, 32), 200);
    XCTAssertEqual(BKRed(cropped, kN, 25, 32), 0);

    // Same with a clipping plane at x = 31.5 cutting away +x.
    r.cropMax = N3VectorMake(63, 63, 63);
    r.clipPlane = N3PlaneMake(N3VectorMake(31.5, 0, 0), N3VectorMake(1, 0, 0));
    r.clipPlaneEnabled = YES;
    NSData *clipped = [self renderTextureWith:r];
    XCTAssertGreaterThan(BKRed(clipped, kN, 39, 32), 200);
    XCTAssertEqual(BKRed(clipped, kN, 25, 32), 0);

    // Turning the plane off brings the full sphere back (checked on the float output).
    r.clipPlaneEnabled = NO;
    BKRenderResult *sync = [r renderWithWidth:kN height:kN error:NULL];
    XCTAssertEqualWithAccuracy([sync valueAtX:39 y:32], 1000.0f, 1.0f);
}

// What: a reduced-resolution interactive frame (ray-cast small, then upscaled) still
// shows the same picture: the sphere's centre stays white and the corner stays black.
- (void)testLowResolutionFrameIsUpscaled
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:NULL];
    XCTAssertTrue([scene setVolumeData:[self sphereVolume] error:NULL]);
    scene.mode = BKRenderModeMIP;
    scene.windowCenter = 0; scene.windowWidth = 2000;
    [scene.camera showStandardView:BKStandardViewAnterior];
    scene.camera.parallelScale = 32;

    [scene recordFrameTime:1.0 atQualityLevel:0];  // pretend full quality is very slow
    [scene beginInteraction];
    id<MTLTexture> tex = [self targetTextureForDevice:device width:kN height:kN];
    id<MTLCommandBuffer> cb = [scene.renderer.commandQueue commandBuffer];
    XCTAssertTrue([scene encodeFrameToTexture:tex commandBuffer:cb error:NULL]);
    XCTAssertEqual(scene.currentQualityLevel, 4);   // coarsest level was used
    NSData *img = [self finishAndReadTexture:tex commandBuffer:cb];
    XCTAssertGreaterThan(BKRed(img, kN, 32, 32), 200);
    XCTAssertLessThan(BKRed(img, kN, 2, 2), 140);    // -1000 -> 0 at WL 0/2000, blurred edges allowed
}

#pragma mark - Window / level

// What: the VR window's WL/WW drag formula, and that WL/WW moves the colours/opacity
// of a simple preset and reshapes the first curve of an advanced preset.
- (void)testWindowLevelDrag
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:NULL];
    XCTAssertTrue([scene setVolumeData:[self sphereVolume] error:NULL]);

    // Formula: WW 400 -> adapter 4 per point.
    scene.windowCenter = 40; scene.windowWidth = 400;
    [scene adjustWindowLevelByDeltaX:10 deltaY:5];
    XCTAssertEqualWithAccuracy(scene.windowCenter, 40 - 5 * 4, 1e-4);
    XCTAssertEqualWithAccuracy(scene.windowWidth, 400 + 10 * 4, 1e-4);
    [scene adjustWindowLevelByDeltaX:-1000 deltaY:0];
    XCTAssertEqualWithAccuracy(scene.windowWidth, 0.1f, 1e-6);  // never below 0.1

    // Advanced preset: one trapezoid curve 100..300 HU (opaque between 150 and 250).
    BKPreset *preset = [[BKPreset alloc] init];
    preset.name = @"Test";
    preset.usesAdvancedCLUT = YES;
    BKPresetCurvePoint pts[] = {{100, 0, 1, 1, 1}, {150, 1, 1, 1, 1}, {250, 1, 1, 1, 1}, {300, 0, 1, 1, 1}};
    preset.advancedCurves = @[[[BKPresetCurve alloc] initWithPoints:pts count:4]];
    preset.windowCenter = 200; preset.windowWidth = 200;
    [scene applyPreset:preset];
    float rgba[4];
    [scene.renderer.transferFunction getRGBA:rgba atValue:200];
    XCTAssertGreaterThan(rgba[3], 0.9f);

    // Move the window to centre 700 / width 200: the curve moves with it.
    scene.windowCenter = 700;
    [scene.renderer.transferFunction getRGBA:rgba atValue:700];
    XCTAssertGreaterThan(rgba[3], 0.9f);
    [scene.renderer.transferFunction getRGBA:rgba atValue:200];
    XCTAssertLessThan(rgba[3], 0.05f);
    // Widen to 400: the curve's ends go to 500 and 900, so 520 HU becomes partly opaque.
    scene.windowWidth = 400;
    [scene.renderer.transferFunction getRGBA:rgba atValue:520];
    XCTAssertGreaterThan(rgba[3], 0.0f);
    [scene.renderer.transferFunction getRGBA:rgba atValue:480];
    XCTAssertLessThan(rgba[3], 0.01f);
}

@end
