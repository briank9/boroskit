// Tests for the plain-C cropping-box maths (BKBoxWidgetMath.h): handles, picking the handle
// or face under the mouse, moving a face, moving/scaling/turning the box, the affine map the
// app hands to VTK's box widget, and the GPU clip planes.

#import <XCTest/XCTest.h>
#import "BKBoxWidgetMath.h"
#import "BKCameraMath.h"

@interface BKBoxWidgetMathTests : XCTestCase
@end

// (Written with BorosKit's neutral vectors, BKVec.h, like the core itself.)
static BOOL BKBoxClose3(BKVec3d a, BKVec3d b, double tol)
{
    return BKV3dDistance(a, b) <= tol;
}

// What: a 40 x 20 x 10 mm box centred at (100, 50, 30).
static BKOrientedBox BKTestBox(void)
{
    return BKBoxMakeAxisAligned(BKV3d(80, 40, 25), BKV3d(120, 60, 35));
}

// What: applies a 4x4 row-major matrix to a point.
static BKVec3d BKApply(const double m[16], BKVec3d p)
{
    return BKV3d(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
                             m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
                             m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]);
}

@implementation BKBoxWidgetMathTests

// Handles sit in the middle of the faces (order -X, +X, -Y, +Y, -Z, +Z) and at the centre;
// rebuilding the box from them gives the same box.
- (void)testHandlesRoundTrip
{
    BKOrientedBox b = BKTestBox();
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFaceMinusX), BKV3d(80, 50, 30), 1e-12));
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFacePlusY), BKV3d(100, 60, 30), 1e-12));
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFacePlusZ), BKV3d(100, 50, 35), 1e-12));
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxHandleCentre), b.centre, 1e-12));
    BKVec3d faces[6];
    for (int f = 0; f < 6; f++) faces[f] = BKBoxHandlePosition(b, f);
    BKOrientedBox r;
    XCTAssertTrue(BKBoxFromHandles(faces, b.centre, &r));
    for (int k = 0; k < 3; k++) {
        XCTAssertEqualWithAccuracy(r.halfSize[k], b.halfSize[k], 1e-12);
        XCTAssertTrue(BKBoxClose3(r.axis[k], b.axis[k], 1e-12));
    }
    BKVec3d corners[8];
    BKBoxCorners(b, corners);
    XCTAssertTrue(BKBoxClose3(corners[0], BKV3d(80, 40, 25), 1e-12));
    XCTAssertTrue(BKBoxClose3(corners[6], BKV3d(120, 60, 35), 1e-12));
}

// Looking down -z at the +Z face: a ray through the +Z handle picks that handle (not the
// centre handle behind it); a ray slightly off still picks it within the radius; a ray far
// away picks nothing. Without a handle, the face the ray enters through is +Z.
- (void)testPicking
{
    BKOrientedBox b = BKTestBox();
    BKVec3d down = BKV3d(0, 0, -1);
    double t = 0;
    XCTAssertEqual(BKBoxPickHandle(b, BKV3d(100, 50, 100), down, 1.0, 0, &t), BKBoxFacePlusZ);
    XCTAssertEqualWithAccuracy(t, 65, 1e-9);
    XCTAssertEqual(BKBoxPickHandle(b, BKV3d(100.8, 50, 100), down, 1.0, 0, NULL), BKBoxFacePlusZ);
    XCTAssertEqual(BKBoxPickHandle(b, BKV3d(110, 55, 100), down, 1.0, 0, NULL), -1);
    // Perspective-style radius growing with distance: 0.01 mm per mm -> 0.65 mm at the face.
    XCTAssertEqual(BKBoxPickHandle(b, BKV3d(100.5, 50, 100), down, 0, 0.01, NULL), BKBoxFacePlusZ);
    XCTAssertEqual(BKBoxPickHandle(b, BKV3d(100.8, 50, 100), down, 0, 0.01, NULL), -1);

    XCTAssertEqual(BKBoxPickFace(b, BKV3d(110, 55, 100), down, &t), BKBoxFacePlusZ);
    XCTAssertEqualWithAccuracy(t, 65, 1e-9);
    // From the left (-x side) looking along +x the ray enters through -X.
    XCTAssertEqual(BKBoxPickFace(b, BKV3d(0, 45, 28), BKV3d(1, 0, 0), NULL), BKBoxFaceMinusX);
    // Missing the box, and starting inside it, give -1.
    XCTAssertEqual(BKBoxPickFace(b, BKV3d(0, 0, 100), down, NULL), -1);
    XCTAssertEqual(BKBoxPickFace(b, b.centre, down, NULL), -1);
}

// Dragging the +X face 6 mm outwards (plus a sideways part that must be ignored) makes the
// box 6 mm longer; the -X face stays. A drag inwards past the other face stops at the
// minimum size.
- (void)testMoveFace
{
    BKOrientedBox b = BKTestBox();
    BKBoxMoveFace(&b, BKBoxFacePlusX, BKV3d(6, 3, -2), 0.5);
    XCTAssertEqualWithAccuracy(b.halfSize[0], 23, 1e-12);
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFaceMinusX), BKV3d(80, 50, 30), 1e-12));
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFacePlusX), BKV3d(126, 50, 30), 1e-12));

    BKBoxMoveFace(&b, BKBoxFaceMinusY, BKV3d(0, 100, 0), 0.5);   // far past +Y
    XCTAssertEqualWithAccuracy(b.halfSize[1], 0.5, 1e-12);
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFacePlusY), BKV3d(103, 60, 30), 1e-12));
}

// Move, scale (never below the minimum) and the drag helpers.
- (void)testTranslateScale
{
    BKOrientedBox b = BKTestBox();
    BKBoxTranslate(&b, BKV3d(1, 2, 3));
    XCTAssertTrue(BKBoxClose3(b.centre, BKV3d(101, 52, 33), 1e-12));
    BKBoxScale(&b, 2, 0.5);
    XCTAssertEqualWithAccuracy(b.halfSize[0], 40, 1e-12);
    XCTAssertEqualWithAccuracy(b.halfSize[2], 10, 1e-12);
    BKBoxScale(&b, 0.001, 0.5);
    XCTAssertEqualWithAccuracy(b.halfSize[2], 0.5, 1e-12);

    BKOrientedBox c = BKTestBox();
    double diag = BKBoxDiagonal(c);
    XCTAssertEqualWithAccuracy(diag, sqrt(40 * 40 + 20 * 20 + 10 * 10), 1e-9);
    BKVec3d m = BKV3d(0, diag * 0.1, 0);
    XCTAssertEqualWithAccuracy(BKBoxScaleFactorForDrag(c, m, 1), 1.1, 1e-12);
    XCTAssertEqualWithAccuracy(BKBoxScaleFactorForDrag(c, m, -1), 0.9, 1e-12);
}

// Turning: a drag to the right (+x) while looking down -z turns the box around the y axis;
// a drag of one diagonal is one full turn. A 90 degree turn around z swaps the x/y extents
// and keeps the axes perpendicular.
- (void)testRotate
{
    BKOrientedBox b = BKTestBox();
    BKVec3d axis;
    double radians = 0;
    double diag = BKBoxDiagonal(b);
    XCTAssertTrue(BKBoxRotationForDrag(b, BKV3d(0, 0, -1), BKV3d(diag / 4, 0, 0), &axis, &radians));
    XCTAssertTrue(BKBoxClose3(axis, BKV3d(0, 1, 0), 1e-12));
    XCTAssertEqualWithAccuracy(radians, M_PI / 2, 1e-12);
    XCTAssertFalse(BKBoxRotationForDrag(b, BKV3d(0, 0, -1), BKV3d(0, 0, 5), NULL, NULL));

    BKBoxRotate(&b, BKV3d(0, 0, 1), M_PI / 2);
    XCTAssertTrue(BKBoxClose3(b.axis[0], BKV3d(0, 1, 0), 1e-12));
    XCTAssertTrue(BKBoxClose3(BKBoxHandlePosition(b, BKBoxFacePlusX), BKV3d(100, 70, 30), 1e-9));
    XCTAssertEqualWithAccuracy(BKV3dDot(b.axis[0], b.axis[1]), 0, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDot(b.axis[1], b.axis[2]), 0, 1e-12);
    XCTAssertTrue(BKBoxContainsPoint(b, BKV3d(100, 69, 30)));
    XCTAssertFalse(BKBoxContainsPoint(b, BKV3d(119, 50, 30)));   // was inside before the turn
}

// The affine map carries every handle and corner of one box onto the matching ones of
// another (moved, stretched and turned) box.
- (void)testAffineMap
{
    BKOrientedBox a = BKTestBox();
    BKOrientedBox b = a;
    BKBoxMoveFace(&b, BKBoxFaceMinusZ, BKV3d(0, 0, -4), 0.5);
    BKBoxRotate(&b, BKV3dNormalize(BKV3d(1, 2, 3)), 0.7);
    BKBoxTranslate(&b, BKV3d(-5, 7, 1));
    double m[16];
    XCTAssertTrue(BKBoxAffineMap(a, b, m));
    for (int h = 0; h < BKBoxHandleCount; h++)
        XCTAssertTrue(BKBoxClose3(BKApply(m, BKBoxHandlePosition(a, h)), BKBoxHandlePosition(b, h), 1e-9));
    BKVec3d ca[8], cb[8];
    BKBoxCorners(a, ca);
    BKBoxCorners(b, cb);
    for (int i = 0; i < 8; i++) XCTAssertTrue(BKBoxClose3(BKApply(m, ca[i]), cb[i], 1e-9));
    XCTAssertEqual(m[15], 1.0);
}

// GPU planes cut exactly the outside of a turned box (same rule as BKClipPlanesPack).
- (void)testPlanes
{
    BKOrientedBox b = BKTestBox();
    BKBoxRotate(&b, BKV3d(0, 0, 1), 0.3);
    float planes[24];
    BKBoxClipPlanes(b, planes);
    BKVec3d tests[4] = { b.centre, BKV3dAdd(BKV3dScale(BKBoxHandlePosition(b, BKBoxFacePlusX), 0.999), BKV3dScale(b.centre, 0.001)),
                         BKV3dAddScaled(b.centre, b.axis[0], 25), BKV3dAddScaled(b.centre, b.axis[2], -6) };
    BOOL expectInside[4] = { YES, YES, NO, NO };
    for (int i = 0; i < 4; i++) {
        BOOL cut = NO;
        for (int f = 0; f < 6; f++) {
            const float *p = planes + 4 * f;
            if (p[0] * tests[i].x + p[1] * tests[i].y + p[2] * tests[i].z + p[3] > 1e-3) cut = YES;
        }
        XCTAssertEqual(!cut, expectInside[i], @"point %d", i);
        XCTAssertEqual(BKBoxContainsPoint(b, tests[i]), expectInside[i], @"point %d", i);
    }
}

@end
