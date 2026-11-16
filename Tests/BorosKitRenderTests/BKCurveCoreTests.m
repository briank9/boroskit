// Tests for the curved-MPR curve maths (BKCurveCore.h).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// The k... tables were RECORDED FROM THE CLASSIC ENGINE (2026-11-15): a scratch harness built Horos'
// old curve code (the curve through the nodes, subdivided at 3 mm and flattened at 0.1 mm, sampled with
// a transported normal) for a dental-arch-like node set and printed its numbers. Expected agreement:
// - the curve through the nodes (Bezier control points): exact (1e-9 mm) - same spline definition;
// - length, sampled positions / tangents / normals, closest point: within the polyline tolerance (both
//   engines approximate the curve with pieces within 0.1 mm of it, so they can differ by up to 0.2 mm;
//   measured on four node sets: length <= 0.01 mm, positions <= 0.09 mm, tangents <= 0.037, normals
//   <= 0.003, a closest point 0.15 mm).
// (Numbers only - no Horos code or data is part of BorosKit.)

#import <XCTest/XCTest.h>
#import "BKCurveCore.h"

@interface BKCurveCoreTests : XCTestCase
@end

static const BKVec3d kArchNodes[7] = { {-40, -20, 900}, {-30, 5, 901}, {-15, 22, 902}, {0, 28, 902.5}, {15, 22, 902}, {30, 5, 901}, {40, -20, 900} };

static const double kArchSegments[6][9] = {
    { -36.965051143723, -11.501732828851, 900.324536080333, -34.377679003030, -2.756064900979, 900.635876281167, -30.000000000000, 5.000000000000, 901.000000000000 },
    { -26.312948383036, 11.532459692599, 901.306679166145, -21.355913248023, 17.362928257305, 901.650801185967, -15.000000000000, 22.000000000000, 902.000000000000 },
    { -10.473083374788, 25.302694096845, 902.248712317973, -5.236541687394, 28.000000000000, 902.500000000000, -0.000000000000, 28.000000000000, 902.500000000000 },
    { 5.236541687394, 28.000000000000, 902.500000000000, 10.473083374788, 25.302694096845, 902.248712317973, 15.000000000000, 22.000000000000, 902.000000000000 },
    { 21.355913248023, 17.362928257305, 901.650801185967, 26.312948383036, 11.532459692599, 901.306679166145, 30.000000000000, 5.000000000000, 901.000000000000 },
    { 34.377679003030, -2.756064900979, 900.635876281167, 36.965051143723, -11.501732828851, 900.324536080333, 40.000000000000, -20.000000000000, 900.000000000000 },
};
static const double kArchLength = 132.544513855331;
static const double kArchSamples[10][9] = { // position, tangent, normal every length/10
    { -40.000000000, -20.000000000, 900.000000000, 0.333158597, 0.942189371, 0.035840468, 0.011948236, 0.033790217, -0.999357524 },
    { -35.607224773, -7.503900725, 900.474253848, 0.348030507, 0.936778465, 0.036343836, 0.012121917, 0.034267464, -0.999339182 },
    { -30.226847400, 4.584625564, 900.980820468, 0.487663106, 0.872080701, 0.040742436, 0.014196351, 0.038740321, -0.999148463 },
    { -22.498607046, 15.296530634, 901.549846696, 0.678523930, 0.733231217, 0.044466380, 0.017949068, 0.043966148, -0.998871768 },
    { -12.374691109, 23.769691377, 902.138071928, 0.846729060, 0.530332662, 0.042393005, 0.020817356, 0.046595718, -0.998696889 },
    { 0.000000000, 28.000000000, 902.500000000, 1.000000000, -0.000000000, -0.000000000, -0.000000000, 0.041690366, -0.999130579 },
    { 12.374691109, 23.769691377, 902.138071928, 0.846729060, -0.530332662, -0.042393005, -0.020817356, 0.046595718, -0.998696889 },
    { 22.498607046, 15.296530634, 901.549846696, 0.678523930, -0.733231217, -0.044466380, -0.017949068, 0.043966148, -0.998871768 },
    { 30.226847400, 4.584625564, 900.980820468, 0.487663106, -0.872080701, -0.040742436, -0.014196351, 0.038740321, -0.999148463 },
    { 35.607224773, -7.503900725, 900.474253848, 0.348030507, -0.936778465, -0.036343836, -0.012121917, 0.034267464, -0.999339182 },
};
static const double kArchClosest[4] = { 0.520929776, 2.757473909, 27.734933173, 902.475749017 }; // relative position, point (probe 5, 40, 905)

static const double kArchProjectedLength = 131.414336001;
static const double kArchProjected[11][10] = { // position, tangent, normal, relative position (projection 0.1,-0.2,1)
    { -40.000000000, -20.000000000, 900.000000000, 0.333158597, 0.942189371, 0.035840468, 0.932819690, -0.323833372, -0.158048643, 0.000000000 },
    { -35.614983595, -7.525016686, 900.473438260, 0.347912998, 0.936822266, 0.036339883, 0.927323214, -0.338163722, -0.160365066, 0.099830162 },
    { -30.259030459, 4.525695993, 900.978099449, 0.486526066, 0.872717094, 0.040709464, 0.862620482, -0.472455504, -0.180753149, 0.199493000 },
    { -22.604008890, 15.182342560, 901.542927477, 0.676353540, 0.735234884, 0.044447210, 0.726621043, -0.656090485, -0.203880201, 0.298826419 },
    { -12.600072785, 23.627885377, 902.126705218, 0.843270862, 0.535795233, 0.042634758, 0.531299497, -0.818942739, -0.216918498, 0.397989174 },
    { -0.356475686, 27.977773748, 902.497950272, 0.999761341, 0.021755975, 0.001984517, 0.021657097, -0.979931994, -0.198152108, 0.497305254 },
    { 12.066482279, 23.963610698, 902.153615873, 0.851400676, -0.522826821, -0.042059541, -0.523915071, -0.843784391, -0.116365371, 0.597250200 },
    { 22.284844241, 15.528112569, 901.563879388, 0.682907363, -0.729148079, -0.044504065, -0.730348171, -0.680163809, -0.062997945, 0.697619890 },
    { 30.117452358, 4.784936009, 900.990069618, 0.491521694, -0.869906533, -0.040853990, -0.870805687, -0.491499322, -0.011219296, 0.798276631 },
    { 35.564997417, -7.388977188, 900.478692682, 0.348669952, -0.936539816, -0.036365341, -0.936593927, -0.349611741, 0.023737044, 0.899075658 },
    { 39.995422658, -19.987055046, 900.000492420, 0.333140272, -0.942195874, -0.035839844, -0.942120299, -0.334155087, 0.027381013, 0.999896343 },
};

// Closed ROI outline ("ends meet" style of the old engine, as polygon / pencil ROIs use): first node
// repeated at the end; control points recorded from the old engine with the scratch harness (2026-11-15).
static const BKVec3d kClosedNodes[6] = { {10, 10, 0}, {40, 5, 0}, {55, 30, 0}, {30, 50, 0}, {5, 35, 0}, {10, 10, 0} };
static const double kClosedSegments[5][9] = {
    { 16.154460169343, 2.756428439382, 0.000000000000, 29.763968699810, 0.339730736397, 0.000000000000, 40.000000000000, 5.000000000000, 0.000000000000 },
    { 49.812286080255, 9.467346170057, 0.000000000000, 56.524620111066, 20.437851174276, 0.000000000000, 55.000000000000, 30.000000000000, 0.000000000000 },
    { 53.325773876702, 40.500451386344, 0.000000000000, 41.718750111727, 49.302590910386, 0.000000000000, 30.000000000000, 50.000000000000, 0.000000000000 },
    { 19.328417560645, 50.635089793947, 0.000000000000, 8.564184004471, 44.549183617880, 0.000000000000, 5.000000000000, 35.000000000000, 0.000000000000 },
    { 1.883211503614, 26.649481167990, 0.000000000000, 4.272343252648, 15.650573704006, 0.000000000000, 10.000000000000, 10.000000000000, 0.000000000000 },
};

@implementation BKCurveCoreTests

// What: the arch as a polyline with the defaults.
- (BKCurvePolyline)archPolyline
{
    BKCurveSegment s[6];
    XCTAssertEqual(BKCurveSegmentsFromNodes(kArchNodes, 7, s), (size_t)6);
    BKCurvePolyline p;
    XCTAssertTrue(BKCurveFlatten(s, 6, BK_CURVE_DEFAULT_MAX_SEGMENT_LENGTH, BK_CURVE_DEFAULT_FLATNESS, &p));
    return p;
}

- (void)testSplineMatchesClassicExactly
{
    BKCurveSegment s[6];
    XCTAssertEqual(BKCurveSegmentsFromNodes(kArchNodes, 7, s), (size_t)6);
    for (int i = 0; i < 6; i++) {
        const double *e = kArchSegments[i];
        double got[9] = { s[i].c0.x, s[i].c0.y, s[i].c0.z, s[i].c1.x, s[i].c1.y, s[i].c1.z, s[i].p1.x, s[i].p1.y, s[i].p1.z };
        for (int k = 0; k < 9; k++) XCTAssertEqualWithAccuracy(got[k], e[k], 1e-9, @"segment %d value %d", i, k);
        XCTAssertEqualWithAccuracy(BKV3dDistance(s[i].p0, kArchNodes[i]), 0, 0);
    }
}

- (void)testSamplingMatchesClassicWithinTolerance
{
    BKCurvePolyline p = [self archPolyline];
    double length = BKCurvePolylineLength(&p);
    XCTAssertEqualWithAccuracy(length, kArchLength, 0.02);
    BKVec3d pos[11], tan[11], nor[11];
    size_t n = BKCurvePolylineSample(&p, length / 10.0, 0, BKV3d(0, 0, -1), pos, tan, nor, 11);
    // 10 samples, or 11 when rounding puts the last one just before the end (the old engine stopped at
    // 10 here); the panorex pads the picture to its full width either way.
    XCTAssertTrue(n == 10 || n == 11, @"%zu samples", n);
    for (size_t i = 0; i < n && i < 10; i++) {
        const double *e = kArchSamples[i];
        XCTAssertLessThan(BKV3dDistance(pos[i], BKV3d(e[0], e[1], e[2])), 0.1, @"position %zu", i);
        XCTAssertLessThan(BKV3dDistance(tan[i], BKV3d(e[3], e[4], e[5])), 0.04, @"tangent %zu", i);
        XCTAssertLessThan(BKV3dDistance(nor[i], BKV3d(e[6], e[7], e[8])), 0.01, @"normal %zu", i);
        XCTAssertEqualWithAccuracy(BKV3dDot(tan[i], nor[i]), 0, 0.02, @"normal across the curve %zu", i);
    }
    BKVec3d closest;
    double rel = BKCurvePolylineClosestToPoint(&p, BKV3d(5, 40, 905), &closest, NULL);
    XCTAssertEqualWithAccuracy(rel, kArchClosest[0], 0.002);
    // Each engine's polyline is within 0.1 mm of the true curve, so their closest points can be up to
    // 0.2 mm apart (measured 0.15 mm for this probe 12 mm off the curve).
    XCTAssertLessThan(BKV3dDistance(closest, BKV3d(kArchClosest[1], kArchClosest[2], kArchClosest[3])), 0.2);
    BKCurvePolylineFree(&p);
}

// What: every polyline point lies on the curve and every piece stays within the flatness of it.
- (void)testFlattenStaysWithinFlatness
{
    BKCurveSegment s[6];
    BKCurveSegmentsFromNodes(kArchNodes, 7, s);
    BKCurvePolyline p;
    XCTAssertTrue(BKCurveFlatten(s, 6, 3.0, 0.1, &p));
    // Dense true-curve samples; each must be within 0.1 mm (+ rounding) of the polyline.
    for (int i = 0; i < 6; i++)
        for (int k = 0; k <= 200; k++) {
            double d;
            BKCurvePolylineClosestToPoint(&p, BKCurveSegmentPoint(&s[i], k / 200.0), NULL, &d);
            XCTAssertLessThan(d, 0.1 + 1e-9);
        }
    XCTAssertEqualWithAccuracy(BKV3dDistance(p.points[0], kArchNodes[0]), 0, 0);
    XCTAssertEqualWithAccuracy(BKV3dDistance(p.points[p.count - 1], kArchNodes[6]), 0, 0);
    BKCurvePolylineFree(&p);
}

- (void)testStraightTwoNodes
{
    BKVec3d nodes[2] = { {0, 0, 0}, {30, 40, 0} };
    BKCurveSegment s[1];
    XCTAssertEqual(BKCurveSegmentsFromNodes(nodes, 2, s), (size_t)1);
    BKCurvePolyline p;
    XCTAssertTrue(BKCurveFlatten(s, 1, 3.0, 0.1, &p));
    XCTAssertEqualWithAccuracy(BKCurvePolylineLength(&p), 50, 1e-9);
    BKVec3d pos, tan, nor;
    XCTAssertTrue(BKCurvePolylineSampleAt(&p, 25, BKV3d(0, 0, 1), &pos, &tan, &nor));
    XCTAssertEqualWithAccuracy(pos.x, 15, 1e-9);
    XCTAssertEqualWithAccuracy(tan.y, 0.8, 1e-9);
    XCTAssertEqualWithAccuracy(nor.z, 1, 1e-9);
    XCTAssertTrue(BKCurvePolylineSampleAt(&p, 999, BKV3d(0, 0, 1), &pos, NULL, NULL));   // clamped to the end
    XCTAssertEqualWithAccuracy(pos.y, 40, 1e-9);
    // closest to a line crossing the segment at its middle
    double dist;
    double rel = BKCurvePolylineClosestToLine(&p, BKV3d(15, 20, -5), BKV3d(0, 0, 1), NULL, &dist);
    XCTAssertEqualWithAccuracy(rel, 0.5, 1e-9);
    XCTAssertEqualWithAccuracy(dist, 0, 1e-9);
    BKCurvePolylineFree(&p);
}

- (void)testPlaneSplitOutlineProjectBoundsPlanarity
{
    BKCurvePolyline p = [self archPolyline];
    // Split at the mid-sagittal plane x = 0: a point exactly on it exists afterwards.
    BKCurvePolyline split;
    XCTAssertTrue(BKCurvePolylineSplitAtPlane(&p, BKV3d(0.37, 0, 0), BKV3d(1, 0, 0), &split));
    int found = 0;
    for (size_t i = 0; i < split.count; i++) if (fabs(split.points[i].x - 0.37) < 1e-9) found++;
    XCTAssertEqual(found, 1);
    XCTAssertEqual(split.count, p.count + 1);
    BKCurvePolylineFree(&split);
    // Outline 5 mm away: every outline point is 5 mm from the curve (the arch bends gently).
    BKCurvePolyline outline;
    XCTAssertTrue(BKCurvePolylineOutline(&p, 5.0, 1.0, BKV3d(0, 0, -1), &outline));
    for (size_t i = 0; i < outline.count; i++) {
        double d;
        BKCurvePolylineClosestToPoint(&p, outline.points[i], NULL, &d);
        XCTAssertEqualWithAccuracy(d, 5.0, 0.05, @"outline point %zu", i);
    }
    BKCurvePolylineFree(&outline);
    // Projection onto z = 0 and planarity.
    BKCurvePolyline flat;
    XCTAssertTrue(BKCurvePolylineProjectToPlane(&p, BKV3d(0, 0, 0), BKV3d(0, 0, 2), &flat));
    for (size_t i = 0; i < flat.count; i++) XCTAssertEqualWithAccuracy(flat.points[i].z, 0, 1e-9);
    XCTAssertTrue(BKCurvePolylineIsPlanar(&flat, 1e-6));
    XCTAssertFalse(BKCurvePolylineIsPlanar(&p, 0.01));   // the arch rises 2.5 mm in z
    BKVec3d c, n;
    XCTAssertTrue(BKCurvePolylineLeastSquaresPlane(&flat, &c, &n));
    XCTAssertEqualWithAccuracy(fabs(n.z), 1, 1e-9);
    BKCurvePolylineFree(&flat);
    BKVec3d top, bottom;
    XCTAssertTrue(BKCurvePolylineBoundingPlanes(&p, BKV3d(0, 1, 0), &top, &bottom));
    XCTAssertEqualWithAccuracy(top.y, 28, 1e-9);        // the front node
    XCTAssertEqualWithAccuracy(bottom.y, -20, 1e-9);    // the end nodes
    BKCurvePolylineFree(&p);
}

// What: stretched-MPR sampling (spacing measured as seen along a tilted vertical) against the old engine
// (measured on 1500 samples: positions <= 0.046 mm, normals <= 0.006, relative positions <= 0.0001).
- (void)testProjectedSamplingMatchesClassic
{
    BKCurvePolyline p = [self archPolyline];
    BKVec3d proj = BKV3d(0.1, -0.2, 1.0);
    BKCurvePolyline pp;
    XCTAssertTrue(BKCurvePolylineProjectToPlane(&p, BKV3d(0, 0, 0), proj, &pp));
    double pl = BKCurvePolylineLength(&pp);
    XCTAssertEqualWithAccuracy(pl, kArchProjectedLength, 0.02);
    BKVec3d pos[12], tan[12], nor[12];
    double rel[12];
    size_t n = BKCurvePolylineSampleProjected(&p, pl / 10.0, 0, proj, pos, tan, nor, rel, 12);
    XCTAssertTrue(n == 10 || n == 11, @"%zu samples", n);
    for (size_t i = 0; i < 10; i++) {
        const double *e = kArchProjected[i];
        XCTAssertLessThan(BKV3dDistance(pos[i], BKV3d(e[0], e[1], e[2])), 0.1, @"position %zu", i);
        XCTAssertLessThan(BKV3dDistance(tan[i], BKV3d(e[3], e[4], e[5])), 0.04, @"tangent %zu", i);
        XCTAssertLessThan(BKV3dDistance(nor[i], BKV3d(e[6], e[7], e[8])), 0.01, @"normal %zu", i);
        XCTAssertEqualWithAccuracy(rel[i], e[9], 0.001, @"relative position %zu", i);
        XCTAssertEqualWithAccuracy(BKV3dDot(nor[i], BKV3dNormalize(proj)), 0, 1e-9, @"normal across the vertical %zu", i);
    }
    BKCurvePolylineFree(&pp);
    BKCurvePolylineFree(&p);
}

// What: the closed outline matches the old engine's control points exactly, joins nearly smoothly at
// the start/end node, and refuses fewer than 3 nodes.
- (void)testClosedSplineMatchesClassicExactly
{
    BKCurveSegment s[5];
    XCTAssertEqual(BKCurveSegmentsFromNodesClosed(kClosedNodes, 6, s), (size_t)5);
    for (int i = 0; i < 5; i++) {
        const double *e = kClosedSegments[i];
        double got[9] = { s[i].c0.x, s[i].c0.y, s[i].c0.z, s[i].c1.x, s[i].c1.y, s[i].c1.z, s[i].p1.x, s[i].p1.y, s[i].p1.z };
        for (int k = 0; k < 9; k++) XCTAssertEqualWithAccuracy(got[k], e[k], 1e-9, @"closed segment %d value %d", i, k);
        XCTAssertEqualWithAccuracy(BKV3dDistance(s[i].p0, kClosedNodes[i]), 0, 0);
    }
    BKVec3d outDir = BKV3dNormalize(BKV3dSub(s[0].c0, s[0].p0));
    BKVec3d inDir = BKV3dNormalize(BKV3dSub(s[4].p1, s[4].c1));
    // The old engine's "ends meet" curve is only nearly smooth at the closing node (its end conditions
    // borrow the neighbouring nodes; about a 5 degree kink here) - kept as is, the outline must match.
    XCTAssertGreaterThan(BKV3dDot(outDir, inDir), 0.99, @"nearly smooth join at the closing node");
    XCTAssertEqual(BKCurveSegmentsFromNodesClosed(kClosedNodes, 2, s), (size_t)0);
}

- (void)testBadInput
{
    BKVec3d same[3] = { {1, 1, 1}, {1, 1, 1}, {2, 2, 2} };
    BKCurveSegment s[2];
    XCTAssertEqual(BKCurveSegmentsFromNodes(same, 3, s), (size_t)0);
    XCTAssertEqual(BKCurveSegmentsFromNodes(kArchNodes, 1, s), (size_t)0);
    BKCurvePolyline p;
    XCTAssertFalse(BKCurveFlatten(NULL, 0, 3, 0.1, &p));
    XCTAssertEqual(BKCurvePolylineSample(&p, 1.0, 0, BKV3d(0, 0, 1), NULL, NULL, NULL, 10), (size_t)0);
    XCTAssertEqualWithAccuracy(BKCurvePolylineLength(NULL), 0, 0);
}

@end
