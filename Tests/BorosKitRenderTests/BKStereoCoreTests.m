// Tests for BKStereoCore (red / blue stereo mixing).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKStereoCore.h"

@interface BKStereoCoreTests : XCTestCase
@end

@implementation BKStereoCoreTests

- (void)testCompose
{
    // Pixel 0: white left, black right. Pixel 1: transparent both -> background grey 0.5 in both channels.
    const unsigned char left[8] = { 255, 255, 255, 255,  0, 0, 0, 0 };
    const unsigned char right[8] = { 0, 0, 0, 255,  0, 0, 0, 0 };
    const float bg[3] = { 0.5f, 0.5f, 0.5f };
    unsigned char out[8];
    BKStereoComposeRedBlue(left, right, 2, bg, out);
    XCTAssertEqual(out[0], 255); XCTAssertEqual(out[1], 0); XCTAssertEqual(out[2], 0); XCTAssertEqual(out[3], 255);
    XCTAssertEqual(out[4], 128); XCTAssertEqual(out[5], 0); XCTAssertEqual(out[6], 128);
    // Pure red counts 0.30, pure blue 0.11.
    const unsigned char red[4] = { 255, 0, 0, 255 }, blue[4] = { 0, 0, 255, 255 };
    BKStereoComposeRedBlue(red, blue, 1, bg, out);
    XCTAssertEqual(out[0], 77); XCTAssertEqual(out[2], 28);
}

- (void)testEyes
{
    XCTAssertEqualWithAccuracy(BKStereoEyeAzimuth(2, 0), -1, 1e-12);
    XCTAssertEqualWithAccuracy(BKStereoEyeAzimuth(2, 1), 1, 1e-12);
}

@end
