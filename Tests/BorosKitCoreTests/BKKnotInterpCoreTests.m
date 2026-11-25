// Tests for BKKnotInterpCore (smooth spline / straight-line interpolation through knots).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// The k... tables were RECORDED FROM THE CLASSIC ENGINE (2026-11-24, vtk-data): a scratch harness linked Boros'
// VTK 8.2 build and printed vtkCardinalSpline / vtkPiecewiseFunction values (default settings, as Spline3D /
// Piecewise3D used them) for the same knots. Agreement measured: identical to 1e-12 (same mathematical
// definition: clamped cubic spline with zero end slopes). Numbers only - no VTK code is part of BorosKit.

#import <XCTest/XCTest.h>
#include "BKKnotInterpCore.h"

@interface BKKnotInterpCoreTests : XCTestCase
@end

// Knot values f(i) = x + y^2/2 - z for the 5 path points of the recorder, at t = i/4; sampled at t = k/20.
static const double kPathValues[5] = { 0, 10 + 12.5 + 2, 20 + 4.5 - 4, 25 + 50 - 8, 40 + 72 };
static const double kVTKSpline[21] = { 0.000000000000, 2.155428571429, 7.446285714286, 14.109428571429, 20.381714285714,
    24.500000000000, 25.256571428571, 23.665428571429, 21.296000000000, 19.717714285714, 20.500000000000, 24.830285714286,
    32.368000000000, 42.390571428571, 54.175428571429, 67.000000000000, 80.066285714286, 92.274571428571,
    102.449714285714, 109.416571428571, 112.000000000000 };
static const double kVTKLinear[21] = { 0, 4.9, 9.8, 14.7, 19.6, 24.5, 23.7, 22.9, 22.1, 21.3, 20.5, 29.8, 39.1, 48.4, 57.7,
    67, 76, 85, 94, 103, 112 };
// Knots added in the order (0,1) (0.3,4) (0.35,2) (0.3,5) (1,0): the second knot at 0.3 replaces the first.
static const double kVTKSpline2[11] = { 1.000000000000, 3.100350227739, 6.089589344366, 5.000000000000, -0.661701393620,
    -3.745408475367, -4.500033340195, -3.714190456587, -2.176494293028, -0.675559318005, 0.0 };

@implementation BKKnotInterpCoreTests

- (void)testSplineMatchesRecordedVTK
{
    double t[8], v[8], m[8], w[8];
    int n = 0;
    for (int i = 0; i < 5; i++) n = BKKnotInsert(t, v, 1, n, 8, i / 4.0, &kPathValues[i]);
    XCTAssertEqual(n, 5);
    XCTAssertEqual(BKSplineClampedMoments(t, v, 1, n, 0, 0, m, w), 0);
    for (int k = 0; k <= 20; k++)
    {
        XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, v, 1, m, n, k / 20.0), kVTKSpline[k], 1e-9, @"spline k=%d", k);
        XCTAssertEqualWithAccuracy(BKLinearEvaluate(t, v, 1, n, k / 20.0), kVTKLinear[k], 1e-9, @"linear k=%d", k);
    }
    // Outside the knots: clamped to the end values (recorded: 0 and 112 for both classes).
    XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, v, 1, m, n, -0.5), 0, 1e-12);
    XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, v, 1, m, n, 1.5), 112, 1e-12);
    XCTAssertEqualWithAccuracy(BKLinearEvaluate(t, v, 1, n, -0.5), 0, 1e-12);
    XCTAssertEqualWithAccuracy(BKLinearEvaluate(t, v, 1, n, 1.5), 112, 1e-12);
}

- (void)testUnevenKnotsAndReplacement
{
    double t[8], v[8], m[8], w[8];
    const double vals[5] = { 1, 4, 2, 5, 0 }, ts[5] = { 0, 0.3, 0.35, 0.3, 1 };
    int n = 0;
    for (int i = 0; i < 5; i++) n = BKKnotInsert(t, v, 1, n, 8, ts[i], &vals[i]);
    XCTAssertEqual(n, 4);
    XCTAssertEqual(v[1], 5);
    BKSplineClampedMoments(t, v, 1, n, 0, 0, m, w);
    for (int k = 0; k <= 10; k++)
        XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, v, 1, m, n, k / 10.0), kVTKSpline2[k], 1e-9, @"k=%d", k);
}

- (void)testHandComputedValues
{
    // Two knots, zero end slopes: the cubic 3x^2 - 2x^3 scaled (recorded VTK: 2, 2.625, 4, 5.375, 6).
    double t[2] = { 0, 1 }, v[2] = { 2, 6 }, m[2], w[2];
    BKSplineClampedMoments(t, v, 1, 2, 0, 0, m, w);
    const double expect[5] = { 2, 2.625, 4, 5.375, 6 };
    for (int k = 0; k <= 4; k++) XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, v, 1, m, 2, k / 4.0), expect[k], 1e-12);
    // Three knots (0,0) (1,1) (2,0): by hand M = (6, -6, 6), S(0.25) = 0.15625, S(0.5) = 0.5.
    double t3[3] = { 0, 1, 2 }, v3[3] = { 0, 1, 0 }, m3[3], w3[3];
    BKSplineClampedMoments(t3, v3, 1, 3, 0, 0, m3, w3);
    XCTAssertEqualWithAccuracy(m3[0], 6, 1e-12);
    XCTAssertEqualWithAccuracy(m3[1], -6, 1e-12);
    XCTAssertEqualWithAccuracy(BKSplineEvaluate(t3, v3, 1, m3, 3, 0.25), 0.15625, 1e-12);
    XCTAssertEqualWithAccuracy(BKSplineEvaluate(t3, v3, 1, m3, 3, 1.75), 0.15625, 1e-12);
}

- (void)testCubicIsReproducedWithExactEndSlopes
{
    // A clamped spline reproduces any cubic exactly when given its true end slopes (uneven knots, 3 coordinates
    // interleaved -> stride 3).
    const double ts[6] = { -1, -0.2, 0.5, 0.6, 1.7, 3 };
    double t[6], y[18], m[6], w[6];
    for (int i = 0; i < 6; i++)
    {
        double x = ts[i];
        t[i] = x;
        y[i * 3 + 0] = 2 * x * x * x - x + 4;
        y[i * 3 + 1] = -x * x * x + 3 * x * x;
        y[i * 3 + 2] = 7;
    }
    BKSplineClampedMoments(t, y, 3, 6, 6 * 1 - 1, 6 * 9 - 1, m, w);     // d/dx (2x^3 - x + 4) = 6x^2 - 1
    for (double x = -1; x <= 3; x += 0.05)
        XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, y, 3, m, 6, x), 2 * x * x * x - x + 4, 1e-9, @"x=%f", x);
    BKSplineClampedMoments(t, y + 1, 3, 6, -3 + 6 * -1, -27 + 18, m, w);  // -3x^2 + 6x
    for (double x = -1; x <= 3; x += 0.05)
        XCTAssertEqualWithAccuracy(BKSplineEvaluate(t, y + 1, 3, m, 6, x), -x * x * x + 3 * x * x, 1e-9, @"x=%f", x);
}

- (void)testEdgeCases
{
    double t[4], v[4], m[4], w[4];
    XCTAssertEqual(BKSplineEvaluate(t, v, 1, m, 0, 0.5), 0);
    XCTAssertEqual(BKLinearEvaluate(t, v, 1, 0, 0.5), 0);
    double one = 3.5;
    int n = BKKnotInsert(t, v, 1, 0, 4, 0.2, &one);
    BKSplineClampedMoments(t, v, 1, n, 0, 0, m, w);
    XCTAssertEqual(BKSplineEvaluate(t, v, 1, m, n, 0.9), 3.5);
    XCTAssertEqual(BKLinearEvaluate(t, v, 1, n, -4), 3.5);
    // No room left -> -1; knots not increasing -> -1.
    for (int i = 0; i < 3; i++) { double x = i; n = BKKnotInsert(t, v, 1, n, 4, 1 + i, &x); }
    XCTAssertEqual(n, 4);
    XCTAssertEqual(BKKnotInsert(t, v, 1, n, 4, 9, &one), -1);
    double bad[3] = { 0, 1, 1 }, by[3] = { 0, 1, 2 };
    XCTAssertEqual(BKSplineClampedMoments(bad, by, 1, 3, 0, 0, m, w), -1);
}

@end
