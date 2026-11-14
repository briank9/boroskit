// Tests for the plain-C camera maths (BKCameraMath.h): screen point -> ray, mouse move ->
// millimetres, the camera-following slab of the 3D window ("clipping-range slab") and the
// turn-around-a-point used while rotating in slab mode. Also one GPU check that the scene's
// camera slab really limits what is drawn (skipped without a Metal GPU).

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import "BorosKitRender.h"
#import "CPRVolumeData.h"

@interface BKCameraMathTests : XCTestCase
@end

// What: an orthographic camera at (0, 0, -100) looking along +z, up = +y, 100 mm high view.
static BKCameraFrame BKTestOrthoCamera(void)
{
    BKCameraFrame c;
    c.position = BKV3d(0, 0, -100);
    c.direction = BKV3d(0, 0, 1);
    c.up = BKV3d(0, 1, 0);
    c.parallelScale = 50;
    c.viewAngle = 30;
    c.perspective = false;
    return c;
}

// (The cores use BorosKit's neutral vectors, BKVec.h - plain C, no Apple simd - so these tests
// are written with them too, ready for a portable test runner.)
static BOOL BKClose3(BKVec3d a, BKVec3d b, double tol)
{
    return BKV3dDistance(a, b) <= tol;
}

@implementation BKCameraMathTests

// Right = direction x up; with +z view and +y up this is -x (as in VTK's convention).
// BKCameraProjectPoint is the exact inverse of BKCameraRayThroughViewPoint: a point on the ray
// through a screen position projects back onto that position (ortho + perspective, several
// points and depths); a point behind a perspective eye is refused. (2026-11-14, 3D point picking.)
- (void)testProjectPointInvertsRay
{
    for (int perspective = 0; perspective <= 1; perspective++) {
        BKCameraFrame c = BKTestOrthoCamera();
        c.perspective = perspective;
        c.viewAngle = 30;
        double pts[4][2] = {{0, 0}, {200, 100}, {399, 7}, {13.5, 187.25}};
        for (int i = 0; i < 4; i++)
            for (double t = 5; t < 400; t *= 3) {
                BKVec3d o, d;
                BKCameraRayThroughViewPoint(c, 400, 200, pts[i][0], pts[i][1], &o, &d);
                double x = -1, y = -1, depth = 0;
                XCTAssertTrue(BKCameraProjectPoint(c, 400, 200, BKV3dAddScaled(o, d, t), &x, &y, &depth));
                XCTAssertEqualWithAccuracy(x, pts[i][0], 1e-6);
                XCTAssertEqualWithAccuracy(y, pts[i][1], 1e-6);
                XCTAssertGreaterThan(depth, perspective ? 0.0 : -1e9);
            }
        if (perspective) {
            double x = 0, y = 0;
            XCTAssertFalse(BKCameraProjectPoint(c, 400, 200, BKV3dAddScaled(c.position, c.direction, -10), &x, &y, NULL));
        }
    }
}

- (void)testRightVector
{
    BKCameraFrame c = BKTestOrthoCamera();
    XCTAssertTrue(BKClose3(BKCameraRight(c), BKV3d(-1, 0, 0), 1e-12));
}

// The view is 100 mm high on 200 points -> 0.5 mm per point; the top-left corner of a
// 400 x 200 view is 100 mm to the left (+x here) and 50 mm up.
- (void)testOrthoRayAndScale
{
    BKCameraFrame c = BKTestOrthoCamera();
    XCTAssertEqualWithAccuracy(BKCameraMillimetresPerViewPoint(c, 200, 0), 0.5, 1e-12);
    BKVec3d o, d;
    BKCameraRayThroughViewPoint(c, 400, 200, 0, 0, &o, &d);
    XCTAssertTrue(BKClose3(o, BKV3d(100, 50, -100), 1e-9));
    XCTAssertTrue(BKClose3(d, BKV3d(0, 0, 1), 1e-12));
    // Centre of the view: the camera position itself.
    BKCameraRayThroughViewPoint(c, 400, 200, 200, 100, &o, &d);
    XCTAssertTrue(BKClose3(o, c.position, 1e-9));
}

// Perspective: 90 degree vertical opening; at the top edge of the view the ray goes 45
// degrees upwards.
- (void)testPerspectiveRay
{
    BKCameraFrame c = BKTestOrthoCamera();
    c.perspective = true;
    c.viewAngle = 90;
    BKVec3d o, d;
    BKCameraRayThroughViewPoint(c, 200, 200, 100, 0, &o, &d);
    XCTAssertTrue(BKClose3(o, c.position, 1e-12));
    XCTAssertTrue(BKClose3(d, BKV3dNormalize(BKV3d(0, 1, 1)), 1e-9));
    // At 10 mm depth the 200-point view is 20 mm high -> 0.1 mm per point.
    XCTAssertEqualWithAccuracy(BKCameraMillimetresPerViewPoint(c, 200, 10), 0.1, 1e-9);
}

// A mouse move of 10 points right and 4 points down = 5 mm along "right", 2 mm down.
- (void)testWorldDelta
{
    BKCameraFrame c = BKTestOrthoCamera();
    BKVec3d m = BKCameraWorldDeltaForViewDelta(c, 200, 0, 10, 4);
    XCTAssertTrue(BKClose3(m, BKV3d(-5, -2, 0), 1e-9));
}

// Slab [0, 20] mm in front of the camera: centre plane 10 mm ahead, facing the view,
// 20 mm thick; points inside/outside are classified correctly, and the packed planes cut
// exactly what lies outside.
- (void)testSlabFromCamera
{
    BKCameraFrame c = BKTestOrthoCamera();
    BKVec3d centre, normal;
    double thickness = 0;
    XCTAssertTrue(BKCameraSlab(c, 0, 20, &centre, &normal, &thickness));
    XCTAssertTrue(BKClose3(centre, BKV3d(0, 0, -90), 1e-12));
    XCTAssertTrue(BKClose3(normal, BKV3d(0, 0, 1), 1e-12));
    XCTAssertEqualWithAccuracy(thickness, 20, 1e-12);
    XCTAssertFalse(BKCameraSlab(c, 5, 5, NULL, NULL, NULL));   // empty slab refused

    XCTAssertTrue(BKCameraSlabContainsPoint(c, 0, 20, BKV3d(30, -7, -95)));
    XCTAssertFalse(BKCameraSlabContainsPoint(c, 0, 20, BKV3d(0, 0, -101)));
    XCTAssertFalse(BKCameraSlabContainsPoint(c, 0, 20, BKV3d(0, 0, -79)));

    float planes[8];
    XCTAssertTrue(BKCameraSlabPlanes(c, 0, 20, planes));
    // "cut" = dot(n, x) + w > 0
    float inside[3] = {3, 4, -90}, before[3] = {0, 0, -100.5f}, after[3] = {0, 0, -79.5f};
    for (int k = 0; k < 2; k++) {
        const float *p = planes + 4 * k;
        XCTAssertLessThanOrEqual(p[0] * inside[0] + p[1] * inside[1] + p[2] * inside[2] + p[3], 0.0f);
    }
    XCTAssertGreaterThan(planes[0] * before[0] + planes[1] * before[1] + planes[2] * before[2] + planes[3], 0.0f);
    XCTAssertGreaterThan(planes[4] * after[0] + planes[5] * after[1] + planes[6] * after[2] + planes[7], 0.0f);
}

// The slab follows the camera: after turning the camera the slab is perpendicular to the
// new viewing direction.
- (void)testSlabFollowsCamera
{
    BKCameraFrame c = BKTestOrthoCamera();
    BKCameraYawPitchAboutPivot(&c, NULL, c.position, 90, 0);
    BKVec3d centre, normal;
    XCTAssertTrue(BKCameraSlab(c, 0, 10, &centre, &normal, NULL));
    XCTAssertTrue(BKClose3(normal, c.direction, 1e-12));
    XCTAssertTrue(BKClose3(centre, BKV3dAddScaled(c.position, c.direction, 5), 1e-9));
}

// Yaw +90 about the camera position turns the view to the camera's left (+x here, since
// right is -x); pitch +90 turns it up. The up vector stays perpendicular.
- (void)testYawPitchSigns
{
    BKCameraFrame c = BKTestOrthoCamera();
    BKCameraYawPitchAboutPivot(&c, NULL, c.position, 90, 0);
    XCTAssertTrue(BKClose3(c.direction, BKV3d(1, 0, 0), 1e-9));
    XCTAssertTrue(BKClose3(c.up, BKV3d(0, 1, 0), 1e-9));
    XCTAssertTrue(BKClose3(c.position, BKV3d(0, 0, -100), 1e-9));   // pivot = position: it stays

    c = BKTestOrthoCamera();
    BKCameraYawPitchAboutPivot(&c, NULL, c.position, 0, 90);
    XCTAssertTrue(BKClose3(c.direction, BKV3d(0, 1, 0), 1e-9));
    XCTAssertTrue(BKClose3(c.up, BKV3d(0, 0, -1), 1e-9));
    XCTAssertEqualWithAccuracy(BKV3dDot(c.direction, c.up), 0, 1e-12);
}

// Turning around a pivot keeps the pivot's place relative to the camera: the pivot stays at
// the same distance and the focal point keeps its distance from the camera.
- (void)testPivotIsKept
{
    BKCameraFrame c = BKTestOrthoCamera();
    BKVec3d focal = BKV3d(0, 0, 0);
    BKVec3d pivot = BKV3d(10, 5, -100);   // a point on the near plane, off centre
    double pivotDistance = BKV3dDistance(pivot, c.position);
    BKCameraYawPitchAboutPivot(&c, &focal, pivot, 25, -13);
    XCTAssertEqualWithAccuracy(BKV3dDistance(focal, c.position), 100, 1e-9);
    XCTAssertEqualWithAccuracy(BKV3dDistance(pivot, c.position), pivotDistance, 1e-9);
    // The focal point still lies straight ahead of the camera.
    XCTAssertTrue(BKClose3(BKV3dNormalize(BKV3dSub(focal, c.position)), c.direction, 1e-9));
    // The pivot is still on the camera's near plane (depth 0 along the view).
    XCTAssertEqualWithAccuracy(BKV3dDot(BKV3dSub(pivot, c.position), c.direction), 0, 1e-9);
}

// GPU: a MIP of a volume whose value grows with z (value = z mm). Without slab the
// brightest value along +z is the last slice; with a camera slab [0, 10] mm starting at
// z = 20 the brightest is about 30.
- (void)testSceneCameraSlabLimitsMIP
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { XCTSkip(@"No Metal GPU available"); return; }
    const NSUInteger n = 48;
    float *bytes = malloc(sizeof(float) * n * n * n);
    for (NSUInteger z = 0; z < n; z++)
        for (NSUInteger i = 0; i < n * n; i++) bytes[z * n * n + i] = (float)z;
    double orientation[9] = {1,0,0, 0,1,0, 0,0,1};
    CPRVolumeData *volume = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:bytes pixelsWide:n pixelsHigh:n pixelsDeep:n
                                                                     origin:N3VectorZero orientation:orientation
                                                                   spacingX:1 spacingY:1 spacingZ:1 freeWhenDone:YES];
    NSError *error = nil;
    BKVolumeScene *scene = [[BKVolumeScene alloc] initWithDevice:device error:&error];
    XCTAssertNotNil(scene, @"%@", error);
    XCTAssertTrue([scene setVolumeData:volume error:&error], @"%@", error);
    scene.mode = BKRenderModeMIP;
    scene.skipsEmptySpace = NO;
    [scene.camera setDirection:N3VectorMake(0, 0, 1) viewUp:N3VectorMake(0, 1, 0)];
    scene.camera.projection = BKProjectionOrthographic;
    scene.camera.focalPoint = N3VectorMake(23.5, 23.5, 21);
    scene.camera.distance = 1;            // camera position at z = 20
    scene.camera.parallelScale = 10;

    BKRenderResult *full = [scene renderFullQualityWithWidth:8 height:8 missValue:NAN error:&error];
    XCTAssertNotNil(full, @"%@", error);
    XCTAssertGreaterThan([full valueAtX:4 y:4], 46.0f);

    scene.viewSlabEnabled = YES;
    scene.viewSlabNear = 0;
    scene.viewSlabFar = 10;
    BKRenderResult *slab = [scene renderFullQualityWithWidth:8 height:8 missValue:NAN error:&error];
    XCTAssertNotNil(slab, @"%@", error);
    XCTAssertEqualWithAccuracy([slab valueAtX:4 y:4], 30.0f, 0.6f);

    scene.viewSlabEnabled = NO;
    BKRenderResult *again = [scene renderFullQualityWithWidth:8 height:8 missValue:NAN error:&error];
    XCTAssertGreaterThan([again valueAtX:4 y:4], 46.0f);
}

@end
