// Tests for view-pinned text labels: BKTextLayoutCore (plain C placement) and BKTextOverlay
// (Core Text drawing layer).
// Original BorosKit code written for this project; contains no third-party code.
//
// What is checked, in plain terms:
//  - a label pinned top-left starts at its offset; right-aligned lines end at the anchor;
//    centred lines are centred; a bottom-aligned block of 3 lines ends at the anchor with lines
//    lineHeight x 1.1 apart (VTK's stacking, as the old mirror copied it); a middle block is centred;
//  - the nine named corners give the expected anchors / alignments;
//  - drawing: the volume window's labels (WL/WW top-left, letters at the edges, angles
//    bottom-right) put ink where they should and nowhere else; hidden / empty labels draw nothing.

#import <XCTest/XCTest.h>
#import "BorosKitDisplay.h"

@interface BKTextOverlayTests : XCTestCase
@end

@implementation BKTextOverlayTests

- (void)testLayoutAlignments
{
    BKTextLayoutItem item = { BKV2f(0, 0), BKV2f(1, 1), BKTextLayoutLeft, BKTextLayoutTop, 14, 1.1f };
    float widths[3] = { 50, 30, 0 };
    BKVec2f tl[3];
    XCTAssertEqual(BKTextLayoutLines(&item, 400, 300, widths, 1, tl), 1u);
    XCTAssertEqualWithAccuracy(tl[0].x, 1, 1e-6);
    XCTAssertEqualWithAccuracy(tl[0].y, 1, 1e-6);

    // Bottom-right, right aligned, 3 lines (the angles label): last line's bottom on the anchor.
    item.anchor = BKV2f(0.99f, 0.99f); item.offset = BKV2f(0, 0);
    item.horizontal = BKTextLayoutRight; item.vertical = BKTextLayoutBottom;
    BKTextLayoutLines(&item, 400, 300, widths, 3, tl);
    float block = BKTextLayoutBlockHeight(&item, 3);
    XCTAssertEqualWithAccuracy(block, 14 + 2 * 14 * 1.1f, 1e-4);
    XCTAssertEqualWithAccuracy(tl[0].x + 50, 396, 1e-4);
    XCTAssertEqualWithAccuracy(tl[1].x + 30, 396, 1e-4);
    XCTAssertEqualWithAccuracy(tl[2].x, 396, 1e-4);           // empty line keeps its row, width 0
    XCTAssertEqualWithAccuracy(tl[2].y + 14, 297, 1e-4);
    XCTAssertEqualWithAccuracy(tl[1].y - tl[0].y, 14 * 1.1f, 1e-4);

    // Centred both ways.
    item.anchor = BKV2f(0.5f, 0.5f); item.horizontal = BKTextLayoutCenter; item.vertical = BKTextLayoutMiddle;
    BKTextLayoutLines(&item, 400, 300, widths, 1, tl);
    XCTAssertEqualWithAccuracy(tl[0].x, 175, 1e-4);
    XCTAssertEqualWithAccuracy(tl[0].y, 143, 1e-4);

    XCTAssertEqual(BKTextLayoutLines(NULL, 1, 1, widths, 1, tl), 0u);
}

- (void)testCornerAnchors
{
    BKVec2f a; int32_t h, v;
    BKTextLayoutCornerAnchor(BKTextCornerTopRight, &a, &h, &v);
    XCTAssertEqual(a.x, 1); XCTAssertEqual(a.y, 0); XCTAssertEqual(h, BKTextLayoutRight); XCTAssertEqual(v, BKTextLayoutTop);
    BKTextLayoutCornerAnchor(BKTextCornerBottom, &a, &h, &v);
    XCTAssertEqual(a.x, 0.5f); XCTAssertEqual(a.y, 1); XCTAssertEqual(h, BKTextLayoutCenter); XCTAssertEqual(v, BKTextLayoutBottom);
    BKTextLayoutCornerAnchor(BKTextCornerLeft, &a, &h, &v);
    XCTAssertEqual(a.x, 0); XCTAssertEqual(a.y, 0.5f); XCTAssertEqual(h, BKTextLayoutLeft); XCTAssertEqual(v, BKTextLayoutMiddle);
    BKTextOverlayItem *item = [BKTextOverlayItem itemWithText:@"x" corner:BKTextCornerBottomRight];
    XCTAssertEqual(item.horizontalAlignment, BKTextAlignRight);
    XCTAssertEqual(item.verticalAlignment, BKTextAlignBottom);
    XCTAssertTrue(CGPointEqualToPoint(item.anchor, CGPointMake(1, 1)));
}

- (void)testLineFramesUseMeasuredFont
{
    BKTextOverlay *overlay = [[BKTextOverlay alloc] init];
    BKTextOverlayItem *item = [BKTextOverlayItem itemWithText:@"S-I: 0.0\nL-R: 90.0" corner:BKTextCornerBottomRight];
    item.offset = CGPointMake(-4, -4);
    NSArray<NSValue *> *frames = [overlay lineFramesForItem:item viewSize:CGSizeMake(300, 200)];
    XCTAssertEqual(frames.count, 2u);
    CGRect a = frames[0].rectValue, b = frames[1].rectValue;
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(a), 296, 1e-3);
    XCTAssertEqualWithAccuracy(CGRectGetMaxX(b), 296, 1e-3);
    XCTAssertEqualWithAccuracy(CGRectGetMaxY(b), 196, 1e-3);
    XCTAssertEqualWithAccuracy(a.size.height, BKTextOverlayLineHeight(12, NO), 1e-6);
    XCTAssertGreaterThan(a.size.width, 20);
    XCTAssertGreaterThan(BKTextOverlayLineWidth(@"WW", 12, YES), BKTextOverlayLineWidth(@"W", 12, YES));
}

// Ink (alpha) inside rect of an RGBA bitmap whose memory row 0 is the TOP row.
static NSUInteger BKInk(const uint8_t *px, size_t w, CGRect r)
{
    NSUInteger n = 0;
    for (size_t y = (size_t)r.origin.y; y < (size_t)CGRectGetMaxY(r); y++)
        for (size_t x = (size_t)r.origin.x; x < (size_t)CGRectGetMaxX(r); x++)
            if (px[4 * (y * w + x) + 3] > 64) n++;
    return n;
}

- (void)testDrawingPutsInkWhereTheLabelsAre
{
    const size_t w = 400, h = 300;
    uint8_t *px = calloc(w * h * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextTranslateCTM(ctx, 0, h);   // view points, origin top-left, y down
    CGContextScaleCTM(ctx, 1, -1);

    BKTextOverlay *overlay = [[BKTextOverlay alloc] init];
    BKTextOverlayItem *wl = [BKTextOverlayItem itemWithText:@"WL: 40 WW: 400 " anchor:CGPointMake(0, 0)];
    wl.offset = CGPointMake(1, 1);
    wl.shadow = YES;
    BKTextOverlayItem *left = [BKTextOverlayItem itemWithText:@"R " anchor:CGPointMake(0.01, 0.5)];
    left.verticalAlignment = BKTextAlignBottom;
    left.bold = YES;
    BKTextOverlayItem *angles = [BKTextOverlayItem itemWithText:@"S-I: 0.0\nL-R: 0.0\nRoll: 0.0" anchor:CGPointMake(0.99, 0.99)];
    angles.horizontalAlignment = BKTextAlignRight;
    angles.verticalAlignment = BKTextAlignBottom;
    BKTextOverlayItem *hidden = [BKTextOverlayItem itemWithText:@"HIDDEN" anchor:CGPointMake(0.5, 0.2)];
    hidden.hidden = YES;
    overlay.items = @[wl, left, angles, hidden, [BKTextOverlayItem itemWithText:nil anchor:CGPointMake(0.5, 0.5)]];
    [overlay drawInContext:ctx viewSize:CGSizeMake(w, h)];
    CGContextRelease(ctx);

    XCTAssertGreaterThan(BKInk(px, w, CGRectMake(0, 0, 140, 20)), 50u, @"WL/WW top-left");
    XCTAssertGreaterThan(BKInk(px, w, CGRectMake(0, 130, 30, 20)), 10u, @"letter just above the middle of the left edge");
    XCTAssertEqual(BKInk(px, w, CGRectMake(0, 152, 30, 20)), 0u, @"nothing below the letter's block");
    XCTAssertGreaterThan(BKInk(px, w, CGRectMake(300, 240, 100, 57)), 50u, @"angles bottom-right");
    XCTAssertEqual(BKInk(px, w, CGRectMake(150, 40, 120, 40)), 0u, @"hidden label not drawn");
    XCTAssertEqual(BKInk(px, w, CGRectMake(150, 120, 120, 60)), 0u, @"empty label, empty middle");
    free(px);
}

@end
