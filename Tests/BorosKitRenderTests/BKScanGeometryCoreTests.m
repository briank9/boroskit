// Tests for BKScanGeometryCore (scan placement, orientation letters, trackball maths).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKScanGeometryCore.h"
#include <math.h>
#include <string.h>

@interface BKScanGeometryCoreTests : XCTestCase
@end

@implementation BKScanGeometryCoreTests

// An axial scan (identity cosines), 0.5 x 0.5 mm pixels, 1 mm slices, origin (-100, -120, 50):
// voxel (10, 20, 3) is at (-95, -110, 53); the inverse brings it back.
- (void)testAxialPlacementAndInverse
{
    double grid[16], place[16], toWorld[16], back[16];
    const double cosines[9] = { 1,0,0, 0,1,0, 0,0,1 }, origin[3] = { -100, -120, 50 };
    BKScanGridToLocal(0.5, 0.5, 1.0, 2.0, grid);
    BKScanPlacement(cosines, origin, place);
    BKMat4dMultiply(place, grid, toWorld);
    double v[3] = { 10, 20, 3 }, w[3], g[3];
    BKMat4dApplyToPoint(toWorld, v, w);
    XCTAssertEqualWithAccuracy(w[0], -95, 1e-12);
    XCTAssertEqualWithAccuracy(w[1], -110, 1e-12);
    XCTAssertEqualWithAccuracy(w[2], 53, 1e-12);
    XCTAssertEqual(BKMat4dInvert(toWorld, back), 1);
    BKMat4dApplyToPoint(back, w, g);
    XCTAssertEqualWithAccuracy(g[0], 10, 1e-9);
    XCTAssertEqualWithAccuracy(g[1], 20, 1e-9);
    XCTAssertEqualWithAccuracy(g[2], 3, 1e-9);
    // Slice interval 0 -> thickness; negative interval keeps its sign.
    BKScanGridToLocal(1, 1, 0, 2.5, grid);
    XCTAssertEqualWithAccuracy(grid[10], 2.5, 1e-12);
    BKScanGridToLocal(1, 1, -0.8, 1, grid);
    XCTAssertEqualWithAccuracy(grid[10], -0.8, 1e-12);
    double singular[16] = { 0 };
    XCTAssertEqual(BKMat4dInvert(singular, back), 0);
}

// A coronal frame (rows along x, columns along -z, normal along y): the origin lands where the cosines put it.
- (void)testCoronalPlacement
{
    const double cosines[9] = { 1,0,0, 0,0,-1, 0,1,0 }, origin[3] = { 5, 7, 9 };
    double place[16], w[3];
    BKScanPlacement(cosines, origin, place);
    const double zero[3] = { 0, 0, 0 };
    BKMat4dApplyToPoint(place, zero, w);   // an orthonormal frame puts the grid origin at the image origin
    XCTAssertEqualWithAccuracy(w[0], 5, 1e-12);
    XCTAssertEqualWithAccuracy(w[1], 7, 1e-12);
    XCTAssertEqualWithAccuracy(w[2], 9, 1e-12);
}

- (void)testOrientationLetters
{
    char s[4];
    const double left[3] = { 1, 0, 0 }, oblique[3] = { -0.8, 0.5, 0.3 }, tiny[3] = { 0.1, 0.1, 0.1 };
    XCTAssertEqual(BKOrientationLetters(left, 0, s), 1); XCTAssertEqual(strcmp(s, "L"), 0);
    XCTAssertEqual(BKOrientationLetters(left, 1, s), 1); XCTAssertEqual(strcmp(s, "R"), 0);
    XCTAssertEqual(BKOrientationLetters(oblique, 0, s), 3); XCTAssertEqual(strcmp(s, "RPS"), 0);
    XCTAssertEqual(BKOrientationLetters(tiny, 0, s), 0); XCTAssertEqual(strcmp(s, ""), 0);
}

- (void)testTrackball
{
    // A quarter turn counter-clockwise around (0, 0): from (1, 0) to (0, 1) = +90 degrees.
    XCTAssertEqualWithAccuracy(BKTrackballSpinDegrees(0, 0, 1, 0, 0, 1), 90, 1e-9);
    // Crossing the +-180 line goes the short way.
    XCTAssertEqualWithAccuracy(BKTrackballSpinDegrees(0, 0, -1, 0.01, -1, -0.01), 1.1459, 1e-3);
    XCTAssertEqualWithAccuracy(BKTrackballDollyFactor(50, 100), pow(1.1, 10), 1e-9);
    XCTAssertEqual(BKTrackballDollyFactor(10, 0), 1.0);
    const unsigned char argb[8] = { 255, 30, 60, 90, 0, 3, 3, 3 };
    float g[2];
    BKScanGreyFromARGB(argb, 2, g);
    XCTAssertEqualWithAccuracy(g[0], 60.0f, 1e-6);
    XCTAssertEqualWithAccuracy(g[1], 3.0f, 1e-6);
}

@end
