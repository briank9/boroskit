// Tests for the plain-C clipping-plane math (BKClipPlanes.h): the VTK -> BorosKit
// conversion used by the Boros 3D window's cropping box, and the GPU packing.

#import <XCTest/XCTest.h>
#import "BKClipPlanes.h"

@interface BKClipPlanesTests : XCTestCase
@end

@implementation BKClipPlanesTests

// What: VTK planes of a 20 x 10 x 6 mm box at (100, 50, 30) mm, in a VTK world scaled by
// `scale`, normals pointing INTO the box (VTK keeps the normal side; vtkBoxWidget with
// InsideOut on). Face centres are the plane origins, as vtkBoxWidget::GetPlanes gives them.
static void BKTestVTKBox(double scale, double inwardSign, double origins[18], double normals[18])
{
    double c[3] = {100, 50, 30}, h[3] = {10, 5, 3};
    for (int axis = 0; axis < 3; axis++)
        for (int side = 0; side < 2; side++) {
            int i = axis * 2 + side;
            double sgn = side ? 1 : -1;   // -: min face, +: max face
            for (int k = 0; k < 3; k++) {
                origins[3 * i + k] = c[k] * scale;
                normals[3 * i + k] = 0;
            }
            origins[3 * i + axis] = (c[axis] + sgn * h[axis]) * scale;
            normals[3 * i + axis] = -sgn * inwardSign;   // inward when inwardSign = 1
        }
}

// The conversion divides by the world scale and keeps exactly the inside of the box.
- (void)testVTKBoxConversion
{
    double o[18], n[18];
    BKTestVTKBox(2.5, 1, o, n);
    N3Plane planes[BK_MAX_CLIP_PLANES];
    NSUInteger count = BKClipPlanesFromVTK(o, n, 6, 2.5, planes);
    XCTAssertEqual(count, 6u);
    XCTAssertTrue(BKClipPlanesKeepPoint(planes, count, N3VectorMake(100, 50, 30)));     // centre
    XCTAssertTrue(BKClipPlanesKeepPoint(planes, count, N3VectorMake(109.9, 54.9, 32.9)));
    XCTAssertFalse(BKClipPlanesKeepPoint(planes, count, N3VectorMake(110.1, 50, 30)));  // just past +x face
    XCTAssertFalse(BKClipPlanesKeepPoint(planes, count, N3VectorMake(100, 44.9, 30)));  // just past -y face
    XCTAssertFalse(BKClipPlanesKeepPoint(planes, count, N3VectorMake(100, 50, 33.1)));  // just past +z face
    N3Vector centre = BKClipPlanesCentroid(planes, count);
    XCTAssertEqualWithAccuracy(centre.x, 100, 1e-9);
    XCTAssertEqualWithAccuracy(centre.y, 50, 1e-9);
    XCTAssertEqualWithAccuracy(centre.z, 30, 1e-9);
}

// Box planes whose normals point OUT of the box (the other VTK convention) still keep the
// inside: the 6-plane safety net orients them towards the box centre.
- (void)testOutwardBoxNormalsAreReoriented
{
    double o[18], n[18];
    BKTestVTKBox(1, -1, o, n);
    N3Plane planes[BK_MAX_CLIP_PLANES];
    NSUInteger count = BKClipPlanesFromVTK(o, n, 6, 1, planes);
    XCTAssertEqual(count, 6u);
    XCTAssertTrue(BKClipPlanesKeepPoint(planes, count, N3VectorMake(100, 50, 30)));
    XCTAssertFalse(BKClipPlanesKeepPoint(planes, count, N3VectorMake(111, 50, 30)));
}

// A single VTK plane keeps its normal side (no box re-orientation for fewer than 6 planes).
- (void)testSingleVTKPlaneKeepsNormalSide
{
    double o[3] = {0, 0, 10}, n[3] = {0, 0, 2};   // un-normalised on purpose
    N3Plane plane;
    XCTAssertEqual(BKClipPlanesFromVTK(o, n, 1, 1, &plane), 1u);
    XCTAssertTrue(BKClipPlanesKeepPoint(&plane, 1, N3VectorMake(0, 0, 11)));
    XCTAssertFalse(BKClipPlanesKeepPoint(&plane, 1, N3VectorMake(0, 0, 9)));
    XCTAssertEqualWithAccuracy(N3VectorLength(plane.normal), 1.0, 1e-12);
}

// Zero normals are dropped and at most 6 planes are kept.
- (void)testZeroNormalsAndLimit
{
    double o[24] = {0}, n[24] = {0};
    for (int i = 0; i < 8; i++) n[3 * i] = (i == 2) ? 0 : 1;
    N3Plane planes[BK_MAX_CLIP_PLANES];
    XCTAssertEqual(BKClipPlanesFromVTK(o, n, 8, 1, planes), (NSUInteger)BK_MAX_CLIP_PLANES);
}

// Packing: (n, w) with unit n and w = -dot(n, point); a point on the plane gives 0.
- (void)testPack
{
    N3Plane planes[2] = { N3PlaneMake(N3VectorMake(1, 2, 3), N3VectorMake(0, 0, 4)),
                          N3PlaneMake(N3VectorMake(5, 0, 0), N3VectorMake(-1, 1, 0)) };
    float out[8];
    XCTAssertEqual(BKClipPlanesPack(planes, 2, out), 2u);
    XCTAssertEqualWithAccuracy(out[2], 1.0f, 1e-6f);
    XCTAssertEqualWithAccuracy(out[3], -3.0f, 1e-6f);
    float onPlane = out[4] * 5 + out[5] * 0 + out[6] * 0 + out[7];
    XCTAssertEqualWithAccuracy(onPlane, 0.0f, 1e-6f);
}

// Orientation: flips exactly the planes that would cut the keep point.
- (void)testOrientToKeepPoint
{
    N3Plane planes[2] = { N3PlaneMake(N3VectorZero, N3VectorMake(1, 0, 0)),
                          N3PlaneMake(N3VectorZero, N3VectorMake(-1, 0, 0)) };
    XCTAssertEqual(BKClipPlanesOrientToKeepPoint(planes, 2, N3VectorMake(3, 0, 0)), 1u);
    XCTAssertTrue(BKClipPlanesKeepPoint(planes, 2, N3VectorMake(3, 0, 0)));
}

@end
