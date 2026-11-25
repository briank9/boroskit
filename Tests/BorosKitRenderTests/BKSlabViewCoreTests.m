// Tests for the plain-C slab view rules (BKSlabViewCore.h). Expected numbers are worked out by hand
// from the rules written in the header.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKSlabViewCore.h"

@interface BKSlabViewCoreTests : XCTestCase
@end

@implementation BKSlabViewCoreTests

// The tool chosen for each button / modifier combination.
- (void)testToolForEvent
{
    BKSlabViewToolIds ids = { 10, 11, 12, 13, 14 };
    const int32_t current = 7;
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, 0, &ids), 7);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonRight, 0, 0, &ids), 10);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonRight, 1, 0, &ids), 7);   // context menu up
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonOther, 0, 0, &ids), 11);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModControl, &ids), 12);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModShift, &ids), 10);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModCommand, &ids), 11);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModOption, &ids), 13);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModCommand | BKSlabViewModOption, &ids), 12);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModCommand | BKSlabViewModControl, &ids), 14);
    // Shift wins over Control (later rule), Command over Shift.
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, BKSlabViewModControl | BKSlabViewModShift, &ids), 10);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonRight, 0, BKSlabViewModShift | BKSlabViewModCommand, &ids), 11);
    XCTAssertEqual(BKSlabViewToolForEvent(current, BKSlabViewButtonLeft, 0, 0, NULL), 7);
}

// Window / level drag: normal scans (deltas truncated) and the three PET styles.
- (void)testWindowLevelDrag
{
    double wl = 400, ww = 2000;
    XCTAssertEqual(BKSlabViewWindowLevelDrag(&wl, &ww, 3.7, -2.9, -1, 0), 1);
    // adapter 20: wl = 400 - (-2) * 20 = 440, ww = 2000 + 3 * 20 = 2060
    XCTAssertEqualWithAccuracy(wl, 440, 1e-12);
    XCTAssertEqualWithAccuracy(ww, 2060, 1e-12);

    wl = 50; ww = 1;
    BKSlabViewWindowLevelDrag(&wl, &ww, -500, 0, -1, 0);   // ww = 1 - 500 * 0.01 = -4 -> 0.1
    XCTAssertEqualWithAccuracy(ww, 0.1, 1e-12);
    XCTAssertEqualWithAccuracy(wl, 50, 1e-12);

    // PET style 1: top of the window follows the drag; min 0 (start 0..10), drag up 5 -> top 15.
    wl = 5; ww = 10;
    BKSlabViewWindowLevelDrag(&wl, &ww, 0, -5, 1, 0);   // endLevel = 10 + 5 * 0.1 = 10.5
    XCTAssertEqualWithAccuracy(ww, 10.5, 1e-12);
    XCTAssertEqualWithAccuracy(wl, 5.25, 1e-12);
    // with a PET minimum value of 2 the centre is lifted
    wl = 5; ww = 10;
    BKSlabViewWindowLevelDrag(&wl, &ww, 0, -5, 1, 2);
    XCTAssertEqualWithAccuracy(wl, 7.25, 1e-12);

    // PET style 2: vertical moves the top, horizontal the bottom (not below 0).
    wl = 5; ww = 10;   // 0..10, adapter 0.1
    BKSlabViewWindowLevelDrag(&wl, &ww, 20, 10, 2, 0);   // top 10 - 1 = 9, bottom 0 + 2 = 2
    XCTAssertEqualWithAccuracy(ww, 7, 1e-12);
    XCTAssertEqualWithAccuracy(wl, 5.5, 1e-12);
    wl = 5; ww = 10;
    BKSlabViewWindowLevelDrag(&wl, &ww, -30, 0, 2, 0);   // bottom -3 -> 0, top 10
    XCTAssertEqualWithAccuracy(ww, 10, 1e-12);
    XCTAssertEqualWithAccuracy(wl, 5, 1e-12);

    XCTAssertEqual(BKSlabViewWindowLevelDrag(NULL, &ww, 0, 0, -1, 0), 0);
    double bad = NAN;
    XCTAssertEqual(BKSlabViewWindowLevelDrag(&bad, &ww, 0, 0, -1, 0), 0);
}

// Picture origin without the window-centre shift, and the double-clicked point.
- (void)testPlacement
{
    BKVec3d o = BKV3d(10, 20, 30), right = BKV3d(1, 0, 0), down = BKV3d(0, -1, 0);
    BKVec3d p = BKSlabViewOriginWithoutWindowCenter(o, right, down, 40, -10, 0.5);
    XCTAssertEqualWithAccuracy(p.x, 30, 1e-12);
    XCTAssertEqualWithAccuracy(p.y, 25, 1e-12);
    XCTAssertEqualWithAccuracy(p.z, 30, 1e-12);

    BKVec3d c = BKSlabViewClickPosition(o, right, down, 100, 50, 300, 0.25);
    // down * (250 * 0.25) = (0, -62.5, 0); right * 25
    XCTAssertEqualWithAccuracy(c.x, 35, 1e-12);
    XCTAssertEqualWithAccuracy(c.y, -42.5, 1e-12);
    XCTAssertEqualWithAccuracy(c.z, 30, 1e-12);
}

// Fusion opacity table.
- (void)testBlendingOpacityTable
{
    float t[256];
    XCTAssertEqual(BKSlabViewBlendingOpacityTable(128, 1, t), 1);
    XCTAssertEqualWithAccuracy(t[0], 0, 1e-7);
    XCTAssertEqualWithAccuracy(t[100], 100.0f / 255.0f, 1e-6);   // a = 256 -> v = i
    XCTAssertEqualWithAccuracy(t[255], 1, 1e-6);
    XCTAssertEqual(BKSlabViewBlendingOpacityTable(128, 0, t), 1);
    // a = 128/3; v = a*i/256 - 8 -> i = 48: 24/... = 42.6667*48/256 - 8 = 0.0 ; i = 255: 42.5 - 8 = 34.5
    XCTAssertEqualWithAccuracy(t[48], 0, 1e-6);
    XCTAssertEqualWithAccuracy(t[255], (float)((128.0 / 3.0 * 255.0 / 256.0 - 8.0) / 255.0), 1e-6);
    XCTAssertEqual(BKSlabViewBlendingOpacityTable(NAN, 0, t), 0);
    XCTAssertEqual(BKSlabViewBlendingOpacityTable(1, 0, NULL), 0);
}

// 16-bit export format and conversion.
- (void)testExportFormatAndConversion
{
    BKSlabViewExportFormat f = BKSlabViewExportFormatForMinimum(-2000);
    XCTAssertEqual(f.isSigned, 1); XCTAssertEqual(f.offset, 0);
    f = BKSlabViewExportFormatForMinimum(0);
    XCTAssertEqual(f.isSigned, 0); XCTAssertEqual(f.offset, 0);
    f = BKSlabViewExportFormatForMinimum(-1024);
    XCTAssertEqual(f.isSigned, 0); XCTAssertEqual(f.offset, -1024);

    const float v[6] = { -1024, -1000.5, 0, 2.5, 3.5, 70000 };
    uint16_t out[6];
    XCTAssertEqual(BKSlabViewValuesTo16Bit(v, 6, f, 1, out), 1);
    XCTAssertEqual(out[0], 0);
    XCTAssertEqual(out[1], 24);       // 23.5 -> ties to even
    XCTAssertEqual(out[2], 1024);
    XCTAssertEqual(out[3], 1026);     // 1026.5 -> 1026
    XCTAssertEqual(out[4], 1028);     // 1027.5 -> 1028
    XCTAssertEqual(out[5], 65535);    // clamped

    BKSlabViewExportFormat s = BKSlabViewExportFormatForMinimum(-3000);
    const float w[3] = { -3000, 40000, NAN };
    XCTAssertEqual(BKSlabViewValuesTo16Bit(w, 3, s, 2, out), 1);
    XCTAssertEqual((int16_t)out[0], -1500);
    XCTAssertEqual((int16_t)out[1], 20000);
    XCTAssertEqual((int16_t)out[2], 0);
    XCTAssertEqual(BKSlabViewValuesTo16Bit(NULL, 3, s, 1, out), 0);
}

// Colour picture layouts, including in place.
- (void)testColourLayouts
{
    uint8_t px[8] = { 10, 20, 30, 99, 40, 50, 60, 0 };
    XCTAssertEqual(BKSlabViewRGBAToOpaqueARGB(px, 2, px), 1);
    const uint8_t argb[8] = { 255, 10, 20, 30, 255, 40, 50, 60 };
    for (int i = 0; i < 8; i++) XCTAssertEqual(px[i], argb[i]);
    XCTAssertEqual(BKSlabViewARGBToRGB(px, 2, px), 1);
    const uint8_t rgb[6] = { 10, 20, 30, 40, 50, 60 };
    for (int i = 0; i < 6; i++) XCTAssertEqual(px[i], rgb[i]);
    XCTAssertEqual(BKSlabViewRGBAToOpaqueARGB(NULL, 1, px), 0);
    XCTAssertEqual(BKSlabViewARGBToRGB(px, 1, NULL), 0);
}

@end
