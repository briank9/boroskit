// Tests for BKROIDraw (ROI drawing into the overlay draw list), checked with the CPU reference rasteriser.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKROIDraw.h"
#include <stdlib.h>

@interface BKROIDrawTests : XCTestCase
@end

@implementation BKROIDrawTests

// A context: image pixel -> view pixel x 2 (zoom 2), shifted by (10, 5).
static BKROIDrawContext Ctx(void)
{
    BKROIDrawContext c;
    memset(&c, 0, sizeof c);
    c.xf.a = 2; c.xf.d = 2; c.xf.tx = 10; c.xf.ty = 5;
    c.color = (BKOverlayColor){ 0, 1, 0, 1 };
    c.thick = 2; c.backing = 1; c.hotA = c.hotB = -1;
    return c;
}

- (void)testMapping
{
    BKROIDrawContext c = Ctx();
    BKVec2f v = BKROIDrawMap(&c, (BKROIPoint){ 3, 4 });
    XCTAssertEqualWithAccuracy(v.x, 16, 0);
    XCTAssertEqualWithAccuracy(v.y, 13, 0);
}

// A horizontal length: green along the line, nothing above it; selected -> blue handles; marker -> red.
- (void)testLengthPixels
{
    const uint32_t W = 64, H = 32;
    BKROIDrawContext c = Ctx();
    BKROIPoint p[2] = { { 2, 5 }, { 22, 5 } };            // view: (14, 15) -> (54, 15)
    BKOverlayList *L = BKOverlayListCreate();
    BKROIDrawLength(L, &c, p, 2, 0, -1);
    float *px = calloc(W * H * 4, sizeof(float));
    BKOverlayRasterize(L, px, W, H);
    float *mid = px + (15 * W + 34) * 4;
    XCTAssertGreaterThan(mid[1], 0.9f);                     // green on the line
    XCTAssertLessThan(px[(5 * W + 34) * 4 + 3], 0.01f);     // nothing well above it

    // Selected: handles drawn in light blue at the ends (bigger than the line's dots).
    BKOverlayListReset(L);
    c.highlight = 1; c.selected = 1;
    BKROIDrawLength(L, &c, p, 2, 0, -1);
    memset(px, 0, W * H * 4 * sizeof(float));
    BKOverlayRasterize(L, px, W, H);
    float *end = px + (15 * W + 14) * 4;
    XCTAssertGreaterThan(end[2], 0.9f);                     // blue at point 0
    XCTAssertGreaterThan(end[0], 0.4f);

    // Marker half way: red at (34, 15).
    BKOverlayListReset(L);
    c.highlight = 0; c.selected = 0;
    BKROIDrawLength(L, &c, p, 2, 0, 0.5f);
    memset(px, 0, W * H * 4 * sizeof(float));
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(mid[0], 0.9f);
    XCTAssertLessThan(mid[1], 0.1f);
    free(px);
    BKOverlayListFree(L);
}

// Rectangle: outline on its edges, empty inside; oval: on its outline, empty at the centre (no centre
// dot), centre dot when asked; arrow: the tip is covered by the head.
- (void)testRectOvalArrow
{
    const uint32_t W = 96, H = 64;
    BKROIDrawContext c = Ctx();
    c.scale = 2;
    float *px = calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    #define A(X, Y) px[((Y) * W + (X)) * 4 + 3]

    BKROIDrawRect(L, &c, 5, 5, 20, 10);                       // view: (20, 15) .. (60, 35)
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(40, 15), 0.9f);                     // top edge
    XCTAssertGreaterThan(A(20, 25), 0.9f);                     // left edge
    XCTAssertLessThan(A(40, 25), 0.01f);                       // inside empty

    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    BKROIDrawOval(L, &c, 20, 15, 10, 5, 0);                    // view: centre (50, 35), half sizes 20 x 10
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(69, 35), 0.5f);                     // right end of the outline
    XCTAssertLessThan(A(50, 35), 0.01f);                       // centre empty
    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    BKROIDrawOval(L, &c, 20, 15, 10, 5, 1);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(50, 35), 0.5f);                     // centre dot

    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    c.thick = 4;
    BKROIDrawArrow(L, &c, (BKROIPoint){ 30, 10 }, (BKROIPoint){ 10, 25 }, 0.5, 0.5, -1);   // tip at view (70, 25)
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(68, 26), 0.5f);                     // head next to the tip
    #undef A
    free(px);
    BKOverlayListFree(L);
}

@end
