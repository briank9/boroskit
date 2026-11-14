// Tests for the native cropping box's plain-C core (BKCropBoxCore.h): what a click grabs and
// which drag it starts, how drags change the box (incl. the smallest box), the drawing geometry
// cut by the thick slab, saving / restoring as 6 planes, bounds and the minimum edge.
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKCropBoxCore.h"

@interface BKCropBoxCoreTests : XCTestCase
@end

// What: a 40 x 20 x 10 mm box centred at (100, 50, 30) (x 80..120, y 40..60, z 25..35).
static BKOrientedBox BKCropTestBox(void)
{
    return BKBoxMakeAxisAligned(simd_make_double3(80, 40, 25), simd_make_double3(120, 60, 35));
}

// What: orthographic camera looking down -z at (100, 50), 100 mm tall view. In a 200 x 200
// point view that is 0.5 mm per point, screen x = +x, screen y (down) = -y; the view centre
// (100, 100) is over (100, 50).
static BKCameraFrame BKCropTestCamera(void)
{
    BKCameraFrame f;
    f.position = simd_make_double3(100, 50, 200);
    f.direction = simd_make_double3(0, 0, -1);
    f.up = simd_make_double3(0, 1, 0);
    f.parallelScale = 50;
    f.viewAngle = 30;
    f.perspective = false;
    return f;
}

static BOOL BKCropClose3(simd_double3 a, simd_double3 b, double tol)
{
    return simd_length(a - b) <= tol;
}

@implementation BKCropBoxCoreTests

// Left click on the +X handle -> face move with red handle + yellow face; on the +Z face away
// from handles -> turn; right -> resize; middle -> move; shift -> move; centre handle -> move
// with the outline highlighted; empty space -> nothing.
- (void)testBeginDragChoosesTheClassicDrag
{
    BKOrientedBox b = BKCropTestBox();
    BKCameraFrame cam = BKCropTestCamera();
    BKCropBoxDrag d;
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 140, 100, BKCropButtonLeft, false, 6, NULL, 0, &d));
    XCTAssertEqual(d.mode, BKCropDragMoveFace);
    XCTAssertEqual(d.part, BKBoxFacePlusX);
    XCTAssertEqual(d.highlightHandle, BKBoxFacePlusX);
    XCTAssertEqual(d.highlightFace, BKBoxFacePlusX);
    XCTAssertEqual(d.highlightOutline, 0);
    XCTAssertEqualWithAccuracy(d.depth, 170, 1e-9);   // handle at z = 30, camera at z = 200

    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonLeft, false, 6, NULL, 0, &d));
    XCTAssertEqual(d.mode, BKCropDragRotate);
    XCTAssertEqual(d.part, BKBoxFacePlusZ);
    XCTAssertEqual(d.highlightFace, BKBoxFacePlusZ);
    XCTAssertEqual(d.highlightHandle, -1);
    XCTAssertEqualWithAccuracy(d.depth, 165, 1e-9);   // +Z face at z = 35

    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonRight, false, 6, NULL, 0, &d));
    XCTAssertEqual(d.mode, BKCropDragScale);
    XCTAssertEqual(d.highlightOutline, 1);
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonMiddle, false, 6, NULL, 0, &d));
    XCTAssertEqual(d.mode, BKCropDragTranslate);
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 140, 100, BKCropButtonLeft, true, 6, NULL, 0, &d));
    XCTAssertEqual(d.mode, BKCropDragTranslate);

    // The +Z handle hides the centre handle from straight above; cut the +Z handle away with a
    // slab plane (keep z <= 32) and the click reaches the centre handle.
    float slab[4] = {0, 0, 1, -32};
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 100, 100, BKCropButtonLeft, false, 6, slab, 1, &d));
    XCTAssertEqual(d.mode, BKCropDragTranslate);
    XCTAssertEqual(d.part, BKBoxHandleCentre);
    XCTAssertEqual(d.highlightHandle, BKBoxHandleCentre);
    XCTAssertEqual(d.highlightOutline, 1);

    // A face point cut away by the slab can't be grabbed; empty space neither.
    XCTAssertFalse(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonLeft, false, 6, slab, 1, &d));
    XCTAssertFalse(BKCropBoxBeginDrag(b, cam, 200, 200, 5, 5, BKCropButtonLeft, false, 6, NULL, 0, &d));
}

// Dragging the +X handle 10 points right moves the +X face 5 mm out (the -X face stays);
// a huge drag inwards stops at the minimum edge; moving and resizing behave as described.
- (void)testContinueDragChangesTheBox
{
    BKCameraFrame cam = BKCropTestCamera();
    BKOrientedBox b = BKCropTestBox();
    BKCropBoxDrag d;
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 140, 100, BKCropButtonLeft, false, 6, NULL, 0, &d));
    XCTAssertTrue(BKCropBoxContinueDrag(&b, &d, cam, 200, 10, 0, 2.0));
    XCTAssertEqualWithAccuracy(b.halfSize[0], 22.5, 1e-9);
    XCTAssertTrue(BKCropClose3(BKBoxHandlePosition(b, BKBoxFacePlusX), simd_make_double3(125, 50, 30), 1e-9));
    XCTAssertTrue(BKCropClose3(BKBoxHandlePosition(b, BKBoxFaceMinusX), simd_make_double3(80, 50, 30), 1e-9));
    BKCropBoxContinueDrag(&b, &d, cam, 200, -1000, 0, 2.0);
    XCTAssertEqualWithAccuracy(2 * b.halfSize[0], 2.0, 1e-9);
    XCTAssertTrue(BKCropClose3(BKBoxHandlePosition(b, BKBoxFaceMinusX), simd_make_double3(80, 50, 30), 1e-9));
    // No motion -> no change.
    XCTAssertFalse(BKCropBoxContinueDrag(&b, &d, cam, 200, 0, 0, 2.0));

    // Move: 20 points down on the screen = 10 mm towards -y.
    b = BKCropTestBox();
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonMiddle, false, 6, NULL, 0, &d));
    XCTAssertTrue(BKCropBoxContinueDrag(&b, &d, cam, 200, 0, 20, 2.0));
    XCTAssertTrue(BKCropClose3(b.centre, simd_make_double3(100, 40, 30), 1e-9));

    // Resize: dragging up grows, dragging down shrinks, around the centre.
    b = BKCropTestBox();
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonRight, false, 6, NULL, 0, &d));
    XCTAssertTrue(BKCropBoxContinueDrag(&b, &d, cam, 200, 0, -10, 2.0));
    XCTAssertGreaterThan(b.halfSize[0], 20.0);
    XCTAssertTrue(BKCropClose3(b.centre, simd_make_double3(100, 50, 30), 1e-9));
    BKOrientedBox before = b;
    XCTAssertTrue(BKCropBoxContinueDrag(&b, &d, cam, 200, 0, 10, 2.0));
    XCTAssertLessThan(b.halfSize[0], before.halfSize[0]);

    // Turn: a drag on the +Z face turns the axes, keeps sizes and centre, axes stay perpendicular.
    b = BKCropTestBox();
    XCTAssertTrue(BKCropBoxBeginDrag(b, cam, 200, 200, 120, 90, BKCropButtonLeft, false, 6, NULL, 0, &d));
    XCTAssertTrue(BKCropBoxContinueDrag(&b, &d, cam, 200, 10, 0, 2.0));
    XCTAssertTrue(BKCropClose3(b.centre, simd_make_double3(100, 50, 30), 1e-9));
    XCTAssertEqualWithAccuracy(b.halfSize[0], 20, 1e-9);
    XCTAssertLessThan(simd_dot(b.axis[0], simd_make_double3(1, 0, 0)), 0.9999);
    XCTAssertEqualWithAccuracy(simd_dot(b.axis[0], b.axis[1]), 0, 1e-9);
    XCTAssertEqualWithAccuracy(simd_dot(b.axis[1], b.axis[2]), 0, 1e-9);
}

// All 12 edges without planes; with a slab plane keeping z <= 32 the top ring disappears and
// the 4 uprights stop at z = 32.
- (void)testOutlineIsCutBySlab
{
    BKOrientedBox b = BKCropTestBox();
    simd_float3 pts[24];
    XCTAssertEqual(BKCropBoxOutline(b, NULL, 0, pts), 24u);
    float slab[4] = {0, 0, 1, -32};
    uint32_t n = BKCropBoxOutline(b, slab, 1, pts);
    XCTAssertEqual(n, 16u);
    float maxZ = -INFINITY;
    for (uint32_t i = 0; i < n; i++) maxZ = fmaxf(maxZ, pts[i].z);
    XCTAssertEqualWithAccuracy(maxZ, 32.0f, 1e-4f);
    // Two slab planes keeping 26 <= z <= 32: only the uprights remain, from 26 to 32.
    float both[8] = {0, 0, 1, -32, 0, 0, -1, 26};
    n = BKCropBoxOutline(b, both, 2, pts);
    XCTAssertEqual(n, 8u);
    for (uint32_t i = 0; i < n; i++) {
        XCTAssertGreaterThanOrEqual(pts[i].z, 26.0f - 1e-4f);
        XCTAssertLessThanOrEqual(pts[i].z, 32.0f + 1e-4f);
    }
}

// Faces as polygons: 4 corners uncut; the -X face cut at z = 32 still has 4 corners, none above
// 32; the +Z face (z = 35) is cut away completely; bad face numbers give nothing.
- (void)testFacePolygonIsCutBySlab
{
    BKOrientedBox b = BKCropTestBox();
    simd_float3 poly[BK_CROP_FACE_MAX_POINTS];
    XCTAssertEqual(BKCropBoxFacePolygon(b, BKBoxFacePlusZ, NULL, 0, poly), 4u);
    for (int i = 0; i < 4; i++) XCTAssertEqualWithAccuracy(poly[i].z, 35.0f, 1e-4f);
    float slab[4] = {0, 0, 1, -32};
    uint32_t n = BKCropBoxFacePolygon(b, BKBoxFaceMinusX, slab, 1, poly);
    XCTAssertEqual(n, 4u);
    for (uint32_t i = 0; i < n; i++) {
        XCTAssertEqualWithAccuracy(poly[i].x, 80.0f, 1e-4f);
        XCTAssertLessThanOrEqual(poly[i].z, 32.0f + 1e-4f);
    }
    XCTAssertEqual(BKCropBoxFacePolygon(b, BKBoxFacePlusZ, slab, 1, poly), 0u);
    XCTAssertEqual(BKCropBoxFacePolygon(b, 7, NULL, 0, poly), 0u);
    // A plane cutting a corner off the -Z face gives a pentagon.
    float corner[4] = {0.70710678f, 0.70710678f, 0, -0.70710678f * (118 + 58)};
    XCTAssertEqual(BKCropBoxFacePolygon(b, BKBoxFaceMinusZ, corner, 1, poly), 5u);
}

// Saving as 6 planes (face centres, normals into the box, scaled) and reading them back gives the
// same turned box; the normals' direction does not matter; invalid planes are refused.
- (void)testSixPlanesRoundTrip
{
    BKOrientedBox b = BKCropTestBox();
    BKBoxRotate(&b, simd_normalize(simd_make_double3(1, 2, 3)), 0.6);
    double origins[18], normals[18];
    BKBoxKeptSidePlanes(b, 2.5, origins, normals);
    // The normal of the -X plane points into the box (along +axis 0); its origin is scaled.
    XCTAssertEqualWithAccuracy(normals[0], b.axis[0].x, 1e-12);
    XCTAssertEqualWithAccuracy(origins[0], BKBoxHandlePosition(b, BKBoxFaceMinusX).x * 2.5, 1e-9);
    BKOrientedBox r;
    XCTAssertTrue(BKBoxFromSixPlanes(origins, normals, 1.0 / 2.5, &r));
    XCTAssertTrue(BKBoxNearlyEqual(b, r, 1e-9));
    // Outward normals (the other convention) give the same box.
    for (int i = 0; i < 18; i++) normals[i] = -normals[i];
    XCTAssertTrue(BKBoxFromSixPlanes(origins, normals, 1.0 / 2.5, &r));
    XCTAssertTrue(BKBoxNearlyEqual(b, r, 1e-9));
    // Invalid input: NaN, zero normals, a non-parallel pair, a flat box.
    double bad[18];
    memcpy(bad, normals, sizeof(bad));
    bad[4] = NAN;
    XCTAssertFalse(BKBoxFromSixPlanes(origins, bad, 1.0, &r));
    double zeros[18] = {0};
    XCTAssertFalse(BKBoxFromSixPlanes(origins, zeros, 1.0, &r));
    memcpy(bad, normals, sizeof(bad));
    bad[3] = normals[6]; bad[4] = normals[7]; bad[5] = normals[8];   // +X plane facing like -Y
    XCTAssertFalse(BKBoxFromSixPlanes(origins, bad, 1.0, &r));
    double flat[18];
    memcpy(flat, origins, sizeof(flat));
    flat[3] = flat[0]; flat[4] = flat[1]; flat[5] = flat[2];          // both X faces at the same place
    XCTAssertFalse(BKBoxFromSixPlanes(flat, normals, 1.0, &r));
}

// Axis-aligned bounds of a cube turned 45 degrees about z grow by sqrt(2) in x and y only.
- (void)testAxisAlignedBounds
{
    BKOrientedBox b = BKBoxMakeAxisAligned(simd_make_double3(-10, -10, -10), simd_make_double3(10, 10, 10));
    BKBoxRotate(&b, simd_make_double3(0, 0, 1), M_PI / 4);
    simd_double3 lo, hi;
    BKBoxAxisAlignedBounds(b, &lo, &hi);
    XCTAssertEqualWithAccuracy(hi.x, 10 * sqrt(2.0), 1e-9);
    XCTAssertEqualWithAccuracy(lo.y, -10 * sqrt(2.0), 1e-9);
    XCTAssertEqualWithAccuracy(hi.z, 10, 1e-9);
}

// Smallest box: 2 mm, or two voxels for coarse scans; nonsense input falls back to 2 mm.
- (void)testMinimumEdge
{
    XCTAssertEqualWithAccuracy(BKCropBoxMinimumEdge(0.2), 2.0, 1e-12);
    XCTAssertEqualWithAccuracy(BKCropBoxMinimumEdge(1.5), 3.0, 1e-12);
    XCTAssertEqualWithAccuracy(BKCropBoxMinimumEdge(NAN), 2.0, 1e-12);
    XCTAssertEqualWithAccuracy(BKCropBoxMinimumEdge(-1), 2.0, 1e-12);
}

// Handle size on screen: orthographic 0.5 mm per point -> 5 points = 2.5 mm anywhere;
// perspective: grows with the distance from the eye.
- (void)testScreenRadius
{
    BKCameraFrame cam = BKCropTestCamera();
    XCTAssertEqualWithAccuracy(BKCropBoxScreenRadius(cam, 200, simd_make_double3(0, 0, 0), 5), 2.5, 1e-9);
    cam.perspective = true;
    double nearR = BKCropBoxScreenRadius(cam, 200, simd_make_double3(100, 50, 100), 5);
    double farR = BKCropBoxScreenRadius(cam, 200, simd_make_double3(100, 50, 0), 5);
    XCTAssertEqualWithAccuracy(farR, 2 * nearR, 1e-9);
}

// Keeping points: no planes keep everything; a point on the cut side is not kept.
- (void)testKeepPoint
{
    float slab[4] = {0, 0, 1, -32};
    XCTAssertTrue(BKCutPlanesKeepPoint(NULL, 0, simd_make_double3(0, 0, 1000)));
    XCTAssertTrue(BKCutPlanesKeepPoint(slab, 1, simd_make_double3(0, 0, 32)));
    XCTAssertFalse(BKCutPlanesKeepPoint(slab, 1, simd_make_double3(0, 0, 32.1)));
}

@end
