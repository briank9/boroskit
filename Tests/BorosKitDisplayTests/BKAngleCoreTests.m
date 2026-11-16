// Tests for BKAngleCore (the arc that marks a measured angle).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKAngleCore.h"
#include <math.h>

@interface BKAngleCoreTests : XCTestCase
@end

@implementation BKAngleCoreTests

// A right angle: the arc starts on arm A, ends on arm B, every point at the radius, inside the angle.
- (void)testArcSpansTheSmallerAngle
{
    BKVec2f out[64];
    BKVec2f v = { 10, 10 };
    uint32_t n = BKAngleArcPoints(v, BKV2f(30, 10), BKV2f(10, 40), 5, 1, out, 64);
    XCTAssertGreaterThanOrEqual(n, (uint32_t)3);
    XCTAssertEqualWithAccuracy(out[0].x, 15, 1e-4);         // on arm A (direction +x)
    XCTAssertEqualWithAccuracy(out[0].y, 10, 1e-4);
    XCTAssertEqualWithAccuracy(out[n - 1].x, 10, 1e-4);     // on arm B (direction +y)
    XCTAssertEqualWithAccuracy(out[n - 1].y, 15, 1e-4);
    for (uint32_t i = 0; i < n; i++) {
        float dx = out[i].x - v.x, dy = out[i].y - v.y;
        XCTAssertEqualWithAccuracy(sqrtf(dx * dx + dy * dy), 5, 1e-4);
        XCTAssertGreaterThanOrEqual(dx, -1e-4); XCTAssertGreaterThanOrEqual(dy, -1e-4);   // inside the quarter
    }
    // 300 degrees one way = 60 degrees the other: the arc takes the 60-degree side.
    BKVec2f b = { 10 + (float)cos(-60 * M_PI / 180) * 20, 10 + (float)sin(-60 * M_PI / 180) * 20 };
    n = BKAngleArcPoints(v, BKV2f(30, 10), b, 5, 0.5f, out, 64);
    for (uint32_t i = 0; i < n; i++) XCTAssertLessThanOrEqual(out[i].y, 10 + 1e-4);   // the -y side only
    XCTAssertEqual(BKAngleArcPoints(v, v, BKV2f(1, 1), 5, 1, out, 64), (uint32_t)0);   // zero-length arm
}

- (void)testRadiusRule
{
    XCTAssertEqualWithAccuracy(BKAngleArcRadius(100, 200, 25), 25, 0);
    XCTAssertEqualWithAccuracy(BKAngleArcRadius(20, 200, 25), 8, 1e-6);   // 40 % of the shorter arm
    XCTAssertEqualWithAccuracy(BKAngleArcRadius(0, 200, 25), 0, 0);
}

// Dynamic angle: two segments whose lines cross outside both; the corner is the crossing, the arc spans
// the acute angle (here 45 degrees).
- (void)testDynamicAngleCorner
{
    BKVec2f c, ta, tb;
    XCTAssertTrue(BKDynamicAngleCorner(BKV2f(10, 0), BKV2f(20, 0), BKV2f(10, 10), BKV2f(20, 20), &c, &ta, &tb));
    XCTAssertEqualWithAccuracy(c.x, 0, 1e-4); XCTAssertEqualWithAccuracy(c.y, 0, 1e-4);
    float dot = (ta.x - c.x) * (tb.x - c.x) + (ta.y - c.y) * (tb.y - c.y);
    XCTAssertEqualWithAccuracy(dot, cosf(45 * (float)M_PI / 180), 1e-4);
    // Segments pointing so the rays make 135 degrees: the second ray is turned -> 45 degrees again.
    XCTAssertTrue(BKDynamicAngleCorner(BKV2f(10, 0), BKV2f(20, 0), BKV2f(-10, 10), BKV2f(-20, 20), &c, &ta, &tb));
    dot = (ta.x - c.x) * (tb.x - c.x) + (ta.y - c.y) * (tb.y - c.y);
    XCTAssertGreaterThan(dot, 0);
    XCTAssertFalse(BKDynamicAngleCorner(BKV2f(0, 0), BKV2f(10, 0), BKV2f(0, 5), BKV2f(10, 5), &c, &ta, &tb));   // parallel
}

// Extensions: from the end nearer the crossing; none when the crossing lies on the segment.
- (void)testExtensionStart
{
    BKVec2f f;
    XCTAssertTrue(BKAngleExtensionStart(BKV2f(10, 0), BKV2f(20, 0), BKV2f(0, 0), &f));
    XCTAssertEqualWithAccuracy(f.x, 10, 0);
    XCTAssertTrue(BKAngleExtensionStart(BKV2f(10, 0), BKV2f(20, 0), BKV2f(30, 0), &f));
    XCTAssertEqualWithAccuracy(f.x, 20, 0);
    XCTAssertFalse(BKAngleExtensionStart(BKV2f(10, 0), BKV2f(20, 0), BKV2f(15, 0), &f));
    XCTAssertFalse(BKAngleExtensionStart(BKV2f(10, 0), BKV2f(10, 0), BKV2f(15, 0), &f));
}

@end
