// BorosKit accuracy check, part 2: the 3D window (BKVolumeCamera + BKVolumeScene +
// BKVolumeRenderer, the same objects BKVolumeView draws on screen).
//
// What is checked: for each of the six standard views (the VR window's view buttons),
// every marker of the phantom appears on the side of the picture where it physically
// belongs, and NOT at the mirrored spot. The 40 mm dots measure 40 mm in the picture.
//
// What each standard view must show (worked out from the physical situation, NOT from
// the engine's code, so the test is an independent check):
//   view (where the camera is)   screen RIGHT is the patient's   screen TOP is the patient's
//   Anterior  (in front)         LEFT                            head (superior)
//   Posterior (behind)           RIGHT                           head
//   Left      (at the left side) back (posterior)                head
//   Right     (at the right)     front (anterior)                head
//   Inferior  (at the feet)      LEFT                            front (anterior)
//   Superior  (above the head)   RIGHT                           front (anterior)
// E.g. standing in front of someone, their left hand is on your right: Anterior view,
// patient left = screen right. From the feet, looking up, with the face at the top, the
// patient's left is again on your right (the same as an axial MPR image).
//
// Two drawing paths are checked: the on-screen path (BKVolumeScene encoding into a GPU
// texture, exactly what BKVolumeView shows) in MIP mode, where markers are identified by
// brightness; and the offscreen path in 3D (composite) mode, where the markers are
// solid objects.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "BKPhantom.h"

static const NSUInteger kViewSize = 256;   // square picture, so mm per pixel is the same both ways

@interface BKAccuracy3DTests : XCTestCase
@end

@implementation BKAccuracy3DTests

#pragma mark - Helpers

// The expected screen directions for each standard view (see the table above).
static void ExpectedAxes(BKStandardView view, N3Vector *screenRight, N3Vector *screenUp, NSString **name)
{
    N3Vector L = N3VectorMake(1, 0, 0), R = N3VectorMake(-1, 0, 0);
    N3Vector P = N3VectorMake(0, 1, 0), A = N3VectorMake(0, -1, 0), S = N3VectorMake(0, 0, 1);
    switch (view) {
        case BKStandardViewAnterior:  *screenRight = L; *screenUp = S; *name = @"Anterior";  break;
        case BKStandardViewPosterior: *screenRight = R; *screenUp = S; *name = @"Posterior"; break;
        case BKStandardViewLeft:      *screenRight = P; *screenUp = S; *name = @"Left";      break;
        case BKStandardViewRight:     *screenRight = A; *screenUp = S; *name = @"Right";     break;
        case BKStandardViewInferior:  *screenRight = L; *screenUp = A; *name = @"Inferior";  break;
        case BKStandardViewSuperior:  *screenRight = R; *screenUp = A; *name = @"Superior";  break;
    }
}

// Where a patient point must appear in the picture: the camera looks at its focal point
// (picture centre); the picture is 2 x parallelScale mm tall. Pixel (i, j) has its centre
// at coordinates (i, j); y grows downward.
static CGPoint ExpectedPixel(N3Vector p, N3Vector focal, double parallelScale, N3Vector right, N3Vector up)
{
    double mmPerPixel = 2.0 * parallelScale / kViewSize;
    N3Vector d = N3VectorSubtract(p, focal);
    return CGPointMake(N3VectorDotProduct(d, right) / mmPerPixel + 0.5 * kViewSize - 0.5,
                       -N3VectorDotProduct(d, up) / mmPerPixel + 0.5 * kViewSize - 0.5);
}

// A pixel box around where a marker must appear (its whole extent plus 1 mm).
static CGRect ExpectedBox(BKPhantomMarker *m, N3Vector focal, double parallelScale, N3Vector right, N3Vector up)
{
    double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    for (int c = 0; c < 8; c++) {
        N3Vector corner = N3VectorMake((c & 1) ? m.boxMax.x : m.boxMin.x, (c & 2) ? m.boxMax.y : m.boxMin.y,
                                       (c & 4) ? m.boxMax.z : m.boxMin.z);
        CGPoint q = ExpectedPixel(corner, focal, parallelScale, right, up);
        minX = fmin(minX, q.x); maxX = fmax(maxX, q.x); minY = fmin(minY, q.y); maxY = fmax(maxY, q.y);
    }
    double m1 = 1.0 / (2.0 * parallelScale / kViewSize);
    return CGRectMake(floor(minX - m1), floor(minY - m1), ceil(maxX - minX + 2 * m1), ceil(maxY - minY + 2 * m1));
}

// A CPU-readable texture to stand in for the screen.
static id<MTLTexture> ScreenTexture(id<MTLDevice> device)
{
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:kViewSize height:kViewSize mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModeShared;
#if TARGET_OS_OSX
    if (!device.hasUnifiedMemory) desc.storageMode = MTLStorageModeManaged;
#endif
    return [device newTextureWithDescriptor:desc];
}

// Draws one frame of the scene exactly as the on-screen view does and reads back the
// grey level of each pixel (0..255) as floats, for the spot-finding tools.
- (NSData *)drawSceneFrame:(BKVolumeScene *)scene
{
    id<MTLTexture> tex = ScreenTexture(scene.renderer.device);
    id<MTLCommandBuffer> cb = [scene.renderer.commandQueue commandBuffer];
    NSError *error = nil;
    XCTAssertTrue([scene encodeFrameToTexture:tex commandBuffer:cb error:&error], @"%@", error);
#if TARGET_OS_OSX
    if (tex.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:tex];
        [blit endEncoding];
    }
#endif
    [cb commit];
    [cb waitUntilCompleted];
    NSMutableData *rgba = [NSMutableData dataWithLength:kViewSize * kViewSize * 4];
    [tex getBytes:rgba.mutableBytes bytesPerRow:kViewSize * 4 fromRegion:MTLRegionMake2D(0, 0, kViewSize, kViewSize) mipmapLevel:0];
    NSMutableData *grey = [NSMutableData dataWithLength:kViewSize * kViewSize * sizeof(float)];
    const uint8_t *src = rgba.bytes;
    float *dst = grey.mutableBytes;
    for (NSUInteger i = 0; i < kViewSize * kViewSize; i++) dst[i] = src[4 * i];
    return grey;
}

static float PixelValue(NSData *floats, CGPoint p)
{
    long x = lround(p.x), y = lround(p.y);
    if (x < 0 || y < 0 || x >= (long)kViewSize || y >= (long)kViewSize) return NAN;
    return ((const float *)floats.bytes)[y * kViewSize + x];
}

#pragma mark - Tests

// ON-SCREEN PATH, MIP mode, all six standard views, tilted phantom grid.
// The window maps -1000 -> black and 2000 -> white, so each marker has its own grey:
// left sphere (1000) 170, anterior sphere (500) 128, rod (200) 102.
// For each view: each big marker's spot is found where the table says (within half a
// voxel), with its own grey level, and the mirrored spot is empty. In the views that
// show a dot pair side by side, the pair measures 40 mm.
- (void)testStandardViewsOnScreenPathMIP
{
    if (!MTLCreateSystemDefaultDevice()) { XCTSkip(@"No Metal GPU available"); return; }
    BKPhantom *ph = [BKPhantom phantomWithGrid:BKPhantomGridTilted];
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:nil error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    XCTAssertTrue([scene setVolumeData:ph.volume error:&error], @"%@", error);
    scene.mode = BKRenderModeMIP;
    scene.windowCenter = 500;
    scene.windowWidth = 3000;
    scene.backgroundColor = simd_make_float4(0, 0, 0, 1);
    scene.camera.projection = BKProjectionOrthographic;
    // Look at the phantom's centre; picture 70 mm tall (0.27 mm per pixel).
    scene.camera.focalPoint = ph.centre;
    scene.camera.parallelScale = 35;

    struct { NSString *marker; float grey; } big[] = { {@"left", 170}, {@"anterior", 128}, {@"rod", 102} };
    for (BKStandardView view = BKStandardViewAnterior; view <= BKStandardViewInferior; view++) {
        N3Vector right, up; NSString *viewName;
        ExpectedAxes(view, &right, &up, &viewName);
        [scene.camera showStandardView:view];
        NSData *img = [self drawSceneFrame:scene];
        double mmPerPixel = 2.0 * scene.camera.parallelScale / kViewSize;
        CGPoint measuredLeft = CGPointZero;   // where the LEFT sphere was actually found

        for (int k = 0; k < 3; k++) {
            BKPhantomMarker *m = [ph marker:big[k].marker];
            CGPoint expected = ExpectedPixel(m.centre, ph.centre, scene.camera.parallelScale, right, up);
            CGRect box = ExpectedBox(m, ph.centre, scene.camera.parallelScale, right, up);
            // Is the marker seen end-on in the middle of the picture (e.g. the left sphere in
            // the Left view)? Then it has no "side" to check, only its position.
            BOOL centred = fabs(expected.x - 0.5 * (kViewSize - 1)) < 1 && fabs(expected.y - 0.5 * (kViewSize - 1)) < 1;
            float peak = 0;
            CGPoint found = BKBrightSpotCentroid(img.bytes, kViewSize, kViewSize, box, 0, &peak);
            double errorMM = hypot(found.x - expected.x, found.y - expected.y) * mmPerPixel;
            if (k == 0) measuredLeft = found;
            NSString *label = [NSString stringWithFormat:@"3D %@ view, %@ marker", viewName, m.name];
            XCTAssertLessThanOrEqual(errorMM, 0.15, @"%@: %.3f mm from where it belongs", label, errorMM);
            XCTAssertEqualWithAccuracy(peak, big[k].grey, 2, @"%@: wrong grey level = wrong marker", label);
            if (!centred) {
                CGPoint mirroredLR = CGPointMake(kViewSize - 1 - expected.x, expected.y);
                CGPoint mirroredTB = CGPointMake(expected.x, kViewSize - 1 - expected.y);
                if (fabs(expected.x - 0.5 * (kViewSize - 1)) > 5)
                    XCTAssertLessThan(PixelValue(img, mirroredLR), 5, @"%@: something at the LEFT-RIGHT mirrored spot", label);
                if (fabs(expected.y - 0.5 * (kViewSize - 1)) > 5)
                    XCTAssertLessThan(PixelValue(img, mirroredTB), 5, @"%@: something at the TOP-BOTTOM mirrored spot", label);
            }
            BKReport(@"3D %@ view (on-screen path, MIP) | %-8@ at pixel %.2f,%.2f (expected %.2f,%.2f), error %.3f mm",
                     viewName, m.name, found.x, found.y, expected.x, expected.y, errorMM);
        }

        // Plain-language side checks for the markers that matter most clinically.
        CGPoint left = measuredLeft;
        if (view == BKStandardViewAnterior || view == BKStandardViewInferior)
            XCTAssertGreaterThan(left.x, kViewSize / 2.0, @"%@ view: the patient's LEFT side must be on the screen's RIGHT", viewName);
        if (view == BKStandardViewPosterior || view == BKStandardViewSuperior)
            XCTAssertLessThan(left.x, kViewSize / 2.0, @"%@ view: the patient's LEFT side must be on the screen's LEFT", viewName);

        // Dot pair 1 (left-right, 40 mm) is seen at full length from the front, back, feet
        // and above; dot pair 2 (front-bottom to back-top) from the left and right sides.
        BOOL pair1 = (view == BKStandardViewAnterior || view == BKStandardViewPosterior ||
                      view == BKStandardViewInferior || view == BKStandardViewSuperior);
        NSString *a = pair1 ? @"dotA1" : @"dotA2", *b = pair1 ? @"dotB1" : @"dotB2";
        CGPoint pa = BKBrightSpotCentroid(img.bytes, kViewSize, kViewSize,
                                          ExpectedBox([ph marker:a], ph.centre, scene.camera.parallelScale, right, up), 0, NULL);
        CGPoint pb = BKBrightSpotCentroid(img.bytes, kViewSize, kViewSize,
                                          ExpectedBox([ph marker:b], ph.centre, scene.camera.parallelScale, right, up), 0, NULL);
        double d = hypot(pa.x - pb.x, pa.y - pb.y) * mmPerPixel;
        XCTAssertEqualWithAccuracy(d, 40.0, 0.15, @"%@ view: 40 mm dot pair", viewName);
        BKReport(@"3D %@ view (on-screen path, MIP) | dot pair %@ measures %.3f mm (true 40.000)", viewName, pair1 ? @"1" : @"2", d);
    }
}

// OFFSCREEN PATH, real 3D (composite) rendering, all six standard views, reversed grid.
// Everything brighter than 0 HU is a solid white object. A marker is "there" when the
// picture is opaque at its expected spot and see-through at the mirrored spot.
// Also one PERSPECTIVE picture (the VR window's default camera type) from the front:
// the left sphere must be on the right half.
- (void)testStandardViewsComposite3D
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    BKPhantom *ph = [BKPhantom phantomWithGrid:BKPhantomGridReversed];
    NSError *error = nil;
    BKVolumeRenderer *renderer = [[BKVolumeRenderer alloc] initWithDevice:device error:&error];
    XCTAssertTrue([renderer setVolumeData:ph.volume error:&error], @"%@", error);
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    [tf addColorPointAtValue:-1000 red:1 green:1 blue:1];
    [tf addColorPointAtValue:2000 red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:-1000 opacity:0];
    [tf addOpacityPointAtValue:0 opacity:0];
    [tf addOpacityPointAtValue:50 opacity:1];
    [tf addOpacityPointAtValue:2000 opacity:1];
    renderer.transferFunction = tf;
    renderer.mode = BKRenderModeComposite;

    BKVolumeCamera *camera = [[BKVolumeCamera alloc] init];
    camera.projection = BKProjectionOrthographic;
    camera.focalPoint = ph.centre;
    camera.parallelScale = 35;

    for (BKStandardView view = BKStandardViewAnterior; view <= BKStandardViewInferior; view++) {
        N3Vector right, up; NSString *viewName;
        ExpectedAxes(view, &right, &up, &viewName);
        [camera showStandardView:view];
        [camera applyToRenderer:renderer aspectRatio:1];
        BKRenderResult *r = [renderer renderWithWidth:kViewSize height:kViewSize error:&error];
        XCTAssertNotNil(r, @"%@", error);
        for (NSString *name in @[@"left", @"anterior", @"rod"]) {
            CGPoint e = ExpectedPixel([ph marker:name].centre, ph.centre, camera.parallelScale, right, up);
            NSString *label = [NSString stringWithFormat:@"3D composite %@ view, %@ marker", viewName, name];
            float here = [r valueAtX:lround(e.x) y:lround(e.y)];
            XCTAssertGreaterThan(here, 0.95f, @"%@: not visible where it belongs", label);
            BOOL offCentreX = fabs(e.x - 0.5 * (kViewSize - 1)) > 5, offCentreY = fabs(e.y - 0.5 * (kViewSize - 1)) > 5;
            float mirrorLR = offCentreX ? [r valueAtX:lround(kViewSize - 1 - e.x) y:lround(e.y)] : 0;
            float mirrorTB = offCentreY ? [r valueAtX:lround(e.x) y:lround(kViewSize - 1 - e.y)] : 0;
            XCTAssertLessThan(mirrorLR, 0.05f, @"%@: visible at the LEFT-RIGHT mirrored spot", label);
            XCTAssertLessThan(mirrorTB, 0.05f, @"%@: visible at the TOP-BOTTOM mirrored spot", label);
            BKReport(@"3D composite %@ view | %-8@ opacity %.2f at expected spot, %.2f / %.2f at mirrored spots",
                     viewName, name, here, mirrorLR, mirrorTB);
        }
    }

    // Perspective from the front: the left sphere must be on the right half of the picture.
    camera.projection = BKProjectionPerspective;
    camera.viewAngle = 30;
    camera.distance = 200;
    [camera showStandardView:BKStandardViewAnterior];
    [camera applyToRenderer:renderer aspectRatio:1];
    BKRenderResult *r = [renderer renderWithWidth:kViewSize height:kViewSize error:&error];
    float *alpha = malloc(kViewSize * kViewSize * sizeof(float));
    memcpy(alpha, r.floatData.bytes, kViewSize * kViewSize * sizeof(float));
    // Look along the image's middle row: find the opaque spot right of and left of centre
    // at the height of the spheres (picture centre).
    double rightSum = 0, leftSum = 0;
    for (NSUInteger x = 0; x < kViewSize; x++) {
        float a = alpha[(kViewSize / 2) * kViewSize + x];
        if (x > kViewSize / 2 + 10) rightSum += a;
        if (x < kViewSize / 2 - 10) leftSum += a;
    }
    free(alpha);
    XCTAssertGreaterThan(rightSum, 5.0, @"perspective front view: the left sphere must be on the screen's RIGHT");
    XCTAssertLessThan(leftSum, 0.5, @"perspective front view: nothing should be on the left at that height");
    BKReport(@"3D perspective Anterior view | opaque pixels on the middle row: right half %.1f, left half %.1f", rightSum, leftSum);
}

@end
