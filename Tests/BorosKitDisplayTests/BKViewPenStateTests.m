// Tests for BKViewPenState (the 2D views' drawing settings), plan step 8d.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKViewPenState.h"

@interface BKViewPenStateTests : XCTestCase
@end

@implementation BKViewPenStateTests

- (void)testDefaultsAndDashes
{
    BKViewPenState s;
    BKViewPenStateReset(&s);
    XCTAssertEqual(s.color[0], 1.0f); XCTAssertEqual(s.lineWidth, 1.0f); XCTAssertEqual(s.dashPattern, 0xFFFFu);
    float d[32];
    XCTAssertEqual(BKViewPenStateDashes(&s, d, 32), 0u);              // not dashed
    s.dashed = 1;
    XCTAssertEqual(BKViewPenStateDashes(&s, d, 32), 0u);              // all drawn = solid
    s.dashPattern = 0x0F0F; s.dashRepeat = 2;                          // 4 on, 4 off, ... x 2 pixels
    uint32_t n = BKViewPenStateDashes(&s, d, 32);
    XCTAssertEqual(n, 4u);
    XCTAssertEqual(d[0], 8.0f); XCTAssertEqual(d[1], 8.0f); XCTAssertEqual(d[2], 8.0f); XCTAssertEqual(d[3], 8.0f);
    s.dashPattern = 0x00F0; s.dashRepeat = 1;                          // starts at its first drawn bit (bit 4)
    n = BKViewPenStateDashes(&s, d, 32);
    XCTAssertEqual(n, 2u);
    XCTAssertEqual(d[0], 4.0f); XCTAssertEqual(d[1], 12.0f);
    s.dashPattern = 0x0001;                                            // odd count padded with a zero
    n = BKViewPenStateDashes(&s, d, 32);
    XCTAssertEqual(n, 2u);
    XCTAssertEqual(d[0], 1.0f); XCTAssertEqual(d[1], 15.0f);

    // A pen from the state: smoothing, opaque when blending is off, dashes.
    s.smoothLines = 1; s.blend = 0; s.dashPattern = 0x0F0F;
    float store[32];
    BKViewPen p = BKViewPenStatePen(&s, 3, store);
    XCTAssertEqual(p.width, 3.0f); XCTAssertEqual(p.smooth, 1); XCTAssertEqual(p.opaque, 1);
    XCTAssertEqual(p.dashCount, 4u); XCTAssertTrue(p.dashes == store);
}

@end
