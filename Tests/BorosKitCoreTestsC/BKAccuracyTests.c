// BorosKit accuracy phantoms: user-visible measurements against EXACT known answers (precision follow-up,
// user decision 2026-11-25; BOROSCMF-FRAMEWORK.md section 8 "every number shown has a written accuracy
// requirement + a phantom test").
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine".
//
// PORTING NOTES:
//   - Plain C99. Run by BOTH test suites: CMake / ctest (bk_core_tests roi_accuracy_*) and the Mac XCTest
//     suite (Tests/BorosKitDisplayTests/BKROIAccuracyTests.m #includes this file), so the Mac and every other
//     platform check identical facts.
//   - Each test states its written requirement (REQ ...) and checks two things: (1) the requirement itself
//     (e.g. within 0.001 mm) and (2) that the double arithmetic is essentially exact (a few double steps),
//     which is what makes the results identical everywhere. The requirements are listed in PRECISION-AUDIT.md.

#include "BKCoreTest.h"
#include "BKROICore.h"
#include <float.h>
#include <math.h>
#include <string.h>

static BKROIShape BKAccShape(int32_t kind, const BKROIPoint *pts, uint32_t n, double sx, double sy)
{
    BKROIShape s;
    memset(&s, 0, sizeof s);
    s.kind = kind;
    s.points = pts;
    s.count = n;
    s.spacingX = sx;
    s.spacingY = sy;
    return s;
}

// REQ-ROI-LENGTH: a length is shown to 0.01 mm; computed exactly (double, error < 1e-9 mm).
void bk_test_roi_accuracy_length(void)
{
    // 3-4-5 triangle in mm with unequal pixel sizes: (0,0) -> (6,16) pixels at 0.5 x 0.25 mm = (3, 4) mm.
    BKROIPoint a = { 0, 0 }, b = { 6, 16 };
    BK_CHECK_SAME(BKROILength(a, b, 0.5, 0.25, 0), 0.5);       // 5 mm = 0.5 cm, exactly
    BK_CHECK_SAME(BKROILength(a, b, 0.5, 0.25, 1), sqrt(292.0)); // in pixels: sqrt(36 + 256)
    // A long oblique line: 300.5 x 400.7 pixels at 0.1 mm -> 50.06... mm, exact value from the formula.
    BKROIPoint c = { 12.25, 7.5 }, d = { 312.75, 408.2 };
    double dx = (312.75 - 12.25) * 0.1, dy = (408.2 - 7.5) * 0.1;
    BK_CHECK_NEAR(BKROILength(c, d, 0.1, 0.1, 0) * 10.0, sqrt(dx * dx + dy * dy), 1e-9);
    BK_CHECK_NEAR(BKROILength(c, d, 0.1, 0.1, 0) * 10.0, 50.086, 0.01);    // the requirement: 0.01 mm
}

// REQ-ROI-ANGLE: an angle is shown to 0.1 degree; computed to 1e-9 degree.
void bk_test_roi_accuracy_angle(void)
{
    BKROIPoint v = { 10, 10 }, east = { 20, 10 }, north = { 10, 0 }, diag = { 20, 0 };
    BK_CHECK_SAME(BKROIAngle(east, v, north, 0, 0), 90.0);
    BK_CHECK_NEAR(BKROIAngle(east, v, diag, 0, 0), 45.0, 1e-12);
    BK_CHECK_NEAR(BKROIAngle(east, v, east, 0, 0), 0.0, 1e-12);                 // straight on: 0
    BKROIPoint west = { 0, 10 };
    BK_CHECK_NEAR(BKROIAngle(east, v, west, 0, 0), 180.0, 1e-12);               // opposite: 180 (acos lost digits here)
    // 60 degrees: (1, 0) and (cos 60, sin 60) scaled to pixels.
    BKROIPoint p60 = { 10 + 50.0, 10 - 50.0 * sqrt(3.0) };
    BK_CHECK_NEAR(BKROIAngle((BKROIPoint){ 110, 10 }, v, p60, 1, 1), 60.0, 1e-9);
    // Unequal pixel sizes: arms (4, 0) and (0, 8) pixels at 0.5 x 0.25 mm = (2, 0) and (0, 2) mm -> 90.
    BKROIPoint arm1 = { 14, 10 }, arm2 = { 10, 18 };
    BK_CHECK_NEAR(BKROIAngle(arm1, v, arm2, 0.5, 0.25), 90.0, 1e-12);
    // Arms (4, 0) and (4, 8) pixels at 0.5 x 0.25 mm = (2, 0) and (2, 2) mm -> 45 (in pixels it would be 63.4).
    BKROIPoint arm3 = { 14, 18 };
    BK_CHECK_NEAR(BKROIAngle(arm1, v, arm3, 0.5, 0.25), 45.0, 1e-12);
    BK_CHECK(BKROIAngle(v, v, arm1, 1, 1) == 0);                                 // zero arm: 0
}

// REQ-ROI-AREA: an area is shown to 0.001 cm2 (0.1 mm2); computed to 1e-9 relative.
void bk_test_roi_accuracy_area(void)
{
    // Square 10 x 10 pixels at 0.5 x 0.7 mm = 5 x 7 mm = 35 mm2 = 0.35 cm2.
    BKROIPoint sq[4] = { { 2, 2 }, { 12, 2 }, { 12, 12 }, { 2, 12 } };
    BKROIShape s = BKAccShape(BKROIKindClosedPolygon, sq, 4, 0.5, 0.7);
    BKROIPointList curve = { sq, 4 };
    BK_CHECK_SAME(BKROIPolygonAreaPixels(sq, 4), 100.0);
    BK_CHECK_NEAR(BKROIAreaCm2(&s, &curve), 0.35, 1e-15);
    // L-shape (concave), area 3 x 1 + 1 x 2 = 5 pixel units, far from the origin (cancellation test).
    BKROIPoint l[6] = { { 1000, 1000 }, { 1003, 1000 }, { 1003, 1001 }, { 1001, 1001 }, { 1001, 1003 }, { 1000, 1003 } };
    BK_CHECK_SAME(BKROIPolygonAreaPixels(l, 6), 5.0);
    // Same shape listed clockwise: same area.
    BKROIPoint lr[6] = { { 1000, 1003 }, { 1001, 1003 }, { 1001, 1001 }, { 1003, 1001 }, { 1003, 1000 }, { 1000, 1000 } };
    BK_CHECK_SAME(BKROIPolygonAreaPixels(lr, 6), 5.0);
    // Rectangle ROI 8.5 x 4 pixels at 0.3 x 0.3 mm: 3.06 mm2.
    BKROIShape r = BKAccShape(BKROIKindRect, NULL, 0, 0.3, 0.3);
    r.rectW = 8.5; r.rectH = 4;
    BK_CHECK_NEAR(BKROIAreaCm2(&r, NULL), 8.5 * 4 * 0.09 / 100.0, 1e-16);
    // Oval, half axes 10 x 5 pixels at 0.4 mm: pi * 4 * 2 mm2.
    BKROIShape o = BKAccShape(BKROIKindOval, NULL, 0, 0.4, 0.4);
    o.rectW = 10; o.rectH = 5;
    double exact = 3.14159265358979323846 * 4.0 * 2.0 / 100.0;
    BK_CHECK(fabs(BKROIAreaCm2(&o, NULL) - exact) <= 4 * DBL_EPSILON * exact);
}

// REQ-ROI-STATS: mean / SD / min / max / total shown to 0.01 units; computed to 1e-9 relative.
void bk_test_roi_accuracy_stats(void)
{
    // Values 1..N in a row (exact answers: mean (N+1)/2, sample SD sqrt(N (N+1) / 12), total N (N+1)/2).
    enum { N = 1000 };
    static float image[N];
    for (int i = 0; i < N; i++) image[i] = (float)(i + 1);
    BKROIRun run = { 0, 0, N - 1 };
    BKROIRunList runs = { &run, 1 };
    BKROIStats s = BKROIStatsOfRuns(&runs, image, N, 1);
    BK_CHECK(s.count == N);
    BK_CHECK_SAME(s.total, N * (N + 1) / 2.0);
    BK_CHECK_SAME(s.mean, (N + 1) / 2.0);
    BK_CHECK_NEAR(s.dev, sqrt(N * (N + 1) / 12.0), 1e-12 * sqrt(N * (N + 1) / 12.0));
    BK_CHECK(s.min == 1 && s.max == N);
    // CT-like values: 2000 pixels of 1000.25 HU plus 2000 of -999.75: mean 0.25, SD exactly 1000 * sqrt(4000/3999).
    static float ct[4000];
    for (int i = 0; i < 4000; i++) ct[i] = i % 2 ? -999.75f : 1000.25f;
    BKROIStats c = BKROIStatsOfValues(ct, 4000);
    BK_CHECK_SAME(c.mean, 0.25);
    BK_CHECK_NEAR(c.dev, 1000.0 * sqrt(4000.0 / 3999.0), 1e-9);
    // One pixel: SD not defined (NaN, as Horos shows it); none: zeros.
    BKROIStats one = BKROIStatsOfValues(image, 1), none = BKROIStatsOfValues(image, 0);
    BK_CHECK(one.count == 1 && one.mean == 1 && isnan(one.dev));
    BK_CHECK(none.count == 0 && none.mean == 0 && none.dev == 0 && none.min == 0 && none.max == 0);
}

// REQ-ROI-CENTRE: the ROI centre is shown to 0.01 mm; computed exactly (double mean of the points).
void bk_test_roi_accuracy_centre(void)
{
    BKROIPoint p[3] = { { 0.1, 0.2 }, { 0.7, 0.4 }, { 0.4, 0.9 } };
    BKROIShape s = BKAccShape(BKROIKindClosedPolygon, p, 3, 1, 1);
    BKROIPoint c = BKROICentroid(&s);
    BK_CHECK_SAME(c.x, (0.1 + 0.7 + 0.4) / 3.0);
    BK_CHECK_SAME(c.y, (0.2 + 0.4 + 0.9) / 3.0);
}
