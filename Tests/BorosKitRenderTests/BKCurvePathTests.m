// Tests for BKCurvePath (the curved-MPR path object over BKCurveCore).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKCurvePath.h"
#import "BKCurveCore.h"

@interface BKCurvePathTests : XCTestCase
@end

static const BKVec3d kNodes[7] = { {-40, -20, 900}, {-30, 5, 901}, {-15, 22, 902}, {0, 28, 902.5}, {15, 22, 902}, {30, 5, 901}, {40, -20, 900} };

@implementation BKCurvePathTests

// What: the path's measurements are exactly the core's on the same polyline (one set of rules).
- (void)testPathUsesTheCorePolyline
{
    BKCurvePath *path = [BKCurvePath pathThroughNodes:kNodes count:7];
    XCTAssertEqual(path.elementCount, (NSUInteger)7);   // moveTo + 6 curves
    XCTAssertEqual(path.subpathCount, (NSUInteger)1);
    BKCurveSegment s[6];
    BKCurveSegmentsFromNodes(kNodes, 7, s);
    BKCurvePolyline p;
    BKCurveFlatten(s, 6, BK_CURVE_DEFAULT_MAX_SEGMENT_LENGTH, BK_CURVE_DEFAULT_FLATNESS, &p);
    XCTAssertEqualWithAccuracy(path.length, BKCurvePolylineLength(&p), 1e-9);
    BKVec3d expected;
    BKCurvePolylineSampleAt(&p, 0.37 * BKCurvePolylineLength(&p), BKV3d(0, 0, 1), &expected, NULL, NULL);
    XCTAssertEqualWithAccuracy(BKV3dDistance([path vectorAtRelativePosition:0.37], expected), 0, 1e-9);
    XCTAssertEqualWithAccuracy(BKV3dDistance(path.vectorAtStart, kNodes[0]), 0, 1e-12);
    XCTAssertEqualWithAccuracy(BKV3dDistance(path.vectorAtEnd, kNodes[6]), 0, 1e-12);
    BKVec3d closest;
    double r = [path relativePositionClosestToVector:[path vectorAtRelativePosition:0.6] closestVector:&closest];
    XCTAssertEqualWithAccuracy(r, 0.6, 1e-6);
    BKCurvePolylineFree(&p);
}

- (void)testCodingCopyEquality
{
    BKCurvePath *path = [BKCurvePath pathThroughNodes:kNodes count:7];
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:path requiringSecureCoding:YES error:&error];
    XCTAssertNotNil(data, @"%@", error);
    BKCurvePath *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[BKCurvePath class] fromData:data error:&error];
    XCTAssertTrue([back isEqualToPath:path]);
    BKCurvePath *copy = [path copy];
    [copy lineTo:BKV3d(50, -30, 900)];
    XCTAssertFalse([copy isEqualToPath:path]);
    XCTAssertEqual(path.elementCount, (NSUInteger)7);   // the copy is independent
}

- (void)testFlattenTransformProjectSplit
{
    BKCurvePath *path = [BKCurvePath pathThroughNodes:kNodes count:7];
    BKCurvePath *flat = [path pathByFlattening:0.1];
    for (NSUInteger i = 1; i < flat.elementCount; i++)
        XCTAssertEqual([flat elementAtIndex:i control1:NULL control2:NULL endpoint:NULL], BKCurvePathLineTo);
    XCTAssertEqualWithAccuracy(flat.length, path.length, 0.02);
    // Translation by (1, 2, 3).
    BKCurveTransform t = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  1, 2, 3, 1 };
    BKCurvePath *moved = [path copy];
    [moved applyTransform:t];
    XCTAssertEqualWithAccuracy(moved.vectorAtStart.z, 903, 1e-12);
    XCTAssertEqualWithAccuracy(moved.length, path.length, 1e-9);
    // Projection onto z = 0 -> planar.
    BKCurvePath *projected = [path pathByProjectingToPlanePoint:BKV3d(0, 0, 0) normal:BKV3d(0, 0, 1)];
    XCTAssertTrue(projected.isPlanar);
    XCTAssertFalse(path.isPlanar);
    // A point is added where the path crosses x = 0.5.
    BKCurvePath *split = [path copy];
    [split addEndpointsAtIntersectionsWithPlanePoint:BKV3d(0.5, 0, 0) normal:BKV3d(1, 0, 0)];
    BOOL found = NO;
    for (NSUInteger i = 0; i < split.elementCount; i++) {
        BKVec3d e;
        [split elementAtIndex:i control1:NULL control2:NULL endpoint:&e];
        if (fabs(e.x - 0.5) < 1e-9) found = YES;
    }
    XCTAssertTrue(found);
    XCTAssertEqualWithAccuracy(split.length, path.length, 0.02);
}

- (void)testOutlines
{
    BKCurvePath *path = [BKCurvePath pathThroughNodes:kNodes count:7];
    BKCurvePath *outline = [path outlinePathAtDistance:4 initialNormal:BKV3d(0, 0, -1) spacing:1];
    XCTAssertNotNil(outline);
    XCTAssertEqual(outline.subpathCount, (NSUInteger)2);
    BKCurvePath *stretched = [path outlinePathAtDistance:4 projectionNormal:BKV3d(0, 0, 1) spacing:1];
    XCTAssertNotNil(stretched);
    for (NSUInteger i = 0; i < stretched.elementCount; i++) {
        BKVec3d e;
        [stretched elementAtIndex:i control1:NULL control2:NULL endpoint:&e];
        double r = [path relativePositionClosestToVector:e closestVector:NULL];
        BKVec3d c = [path vectorAtRelativePosition:r];
        // across the vertical: the outline is 4 mm away in the x-y plane (the arch is nearly flat in z)
        XCTAssertEqualWithAccuracy(hypot(e.x - c.x, e.y - c.y), 4.0, 0.15, @"point %lu", (unsigned long)i);
    }
    XCTAssertNil([path outlinePathAtDistance:4 initialNormal:BKV3d(0, 0, 1) spacing:100]);   // too short for that spacing
}

@end
