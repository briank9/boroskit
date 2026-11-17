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


// Brush outline: the ring just outside a 2 x 2 block, nothing inside.
- (void)testMaskOutline
{
    uint8_t m[16] = { 0,0,0,0, 0,255,255,0, 0,255,255,0, 0,0,0,0 };   // 4 x 4, block at (1..2, 1..2)
    uint8_t o[36];
    XCTAssertEqual(BKROIMaskOutline(m, 4, 4, o), 1);
    // Padded coordinates = mask + 1: block at (2..3, 2..3); ring (1..4, 1..4) minus block.
    XCTAssertEqual(o[2 * 6 + 2], 0);     // inside the brush
    XCTAssertEqual(o[1 * 6 + 1], 255);   // diagonal neighbour
    XCTAssertEqual(o[4 * 6 + 3], 255);   // below
    XCTAssertEqual(o[0 * 6 + 0], 0);     // two away
    XCTAssertEqual(BKROIMaskOutline(NULL, 4, 4, o), 0);
}

// Closed polygon, axis fill, dynamic angle, 2D point, brush, text box connector: pixels where expected.
- (void)testSecondBatchPixels
{
    const uint32_t W = 96, H = 64;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKROIDrawContext c = Ctx();
    c.scale = 2;
    BKOverlayList *L = BKOverlayListCreate();
    #define A(X, Y) px[((Y) * W + (X)) * 4 + 3]
    #define CLEAR() do { BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float)); } while (0)

    BKROIPoint sq[4] = { { 5, 5 }, { 25, 5 }, { 25, 20 }, { 5, 20 } };   // view (20,15)-(60,45)
    BKROIDrawPolygon(L, &c, sq, 4, sq, 4, BKROIPolyClosed, 0, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(20, 30), 0.9f);    // closing side drawn
    XCTAssertLessThan(A(40, 30), 0.01f);      // inside empty

    CLEAR();
    BKROIDrawAxis(L, &c, sq, 4, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertEqualWithAccuracy(A(30, 22), 0.25f, 0.02f);   // 25 % fill inside, away from the axes

    CLEAR();
    BKROIPoint da[4] = { { 5, 5 }, { 25, 5 }, { 5, 10 }, { 25, 20 } };
    BKROIDrawDynamicAngle(L, &c, da, 4, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(21, 15), 0.5f);    // solid end of the first line
    XCTAssertLessThan(A(58, 15), 0.3f);       // faint far end (10 %)

    CLEAR();
    BKROIDraw2DPoint(L, &c, (BKROIPoint){ 20, 15 }, 0, 0);     // view (50, 35), circle radius 8 (zoomed) -> 8 view px
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(50, 35), 0.9f);    // centre dot
    XCTAssertGreaterThan(A(58, 35), 0.3f);    // circle

    CLEAR();
    uint8_t mask[4] = { 255, 255, 255, 255 };
    BKROIDrawBrush(L, &c, mask, 2, 2, 10, 10, 0, NULL, 4);     // view (30,25)-(34,29)
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(32, 27), 0.9f);
    XCTAssertLessThan(A(36, 27), 0.01f);

    CLEAR();
    BKROIDrawTextBox box;
    memset(&box, 0, sizeof box);
    for (int i = 0; i < 6; i++) box.lines[i].image = -1;
    box.scale = 1; box.offsetX = 48; box.offsetY = 32;          // box space centred
    box.boxX = 10; box.boxY = -5; box.boxW = 20; box.boxH = 10;
    box.anchorX = -20; box.anchorY = 0; box.connector = 1;
    BKROIDrawTextBoxItems(L, &c, &box);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(28, 32), 0.9f);    // the connector reaches the anchor (view 28, 32)
    XCTAssertGreaterThan(A(57, 32), 0.9f);    // and starts at the box's left middle (view 58, 32)
    #undef CLEAR
    #undef A
    free(px);
    BKOverlayListFree(L);
}

// The selection box (2026-11-17): a dashed frame `pad` pixels outside the points' bounding box; nothing inside.
- (void)testSelectionBox
{
    const uint32_t W = 128, H = 96;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    BKROIDrawContext c = Ctx();
    BKROIPoint pts[2] = { { 20, 20 }, { 40, 30 } };
    BKVec2f a = BKROIDrawMap(&c, pts[0]), b = BKROIDrawMap(&c, pts[1]);
    BKROIDrawSelectionBox(L, &c, pts, 2, 8);
    BKOverlayRasterize(L, px, W, H);
    #define A(X, Y) px[((Y) * W + (X)) * 4 + 3]
    int left = (int)floorf(a.x - 8 * c.backing), top = (int)floorf(a.y - 8 * c.backing);
    int mid = (int)((a.y + b.y) / 2);
    float edge = 0;
    for (int y = mid - 4; y <= mid + 4; y++) if (A(left, y) > edge) edge = A(left, y);   // dark line + some dashes
    XCTAssertGreaterThan(edge, 0.5f);
    XCTAssertLessThan(A(left + 3, mid), 0.01f);                                            // inside: nothing
    XCTAssertGreaterThan(A((int)((a.x + b.x) / 2), top), 0.3f);                            // top edge drawn
    #undef A
    BKOverlayListReset(L);
    BKROIDrawSelectionBox(L, &c, pts, 0, 8);                                                // no points: nothing
    uint32_t nv = 99;
    BKOverlayListVertices(L, &nv);
    XCTAssertEqual(nv, 0u);
    free(px);
    BKOverlayListFree(L);
}

// Dynamic angle with nearly parallel lines (2026-11-17, "moved corner"): the crossing is far away, so the arc and a
// dashed copy of the other line are drawn at line A's end nearer the crossing - nothing far above the lines.
- (void)testDynamicAngleFarCrossingMovedCorner
{
    const uint32_t W = 128, H = 128;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    BKROIDrawContext c = Ctx();                       // view = 2 x model + (10, 5)
    BKROIPoint pts[4] = { { 10, 55 }, { 10, 40 }, { 30, 40 }, { 33, 55 } };   // lines meeting far above
    BKROIDrawDynamicAngle(L, &c, pts, 4, NULL);
    BKOverlayRasterize(L, px, W, H);
    #define A(X, Y) px[((Y) * W + (X)) * 4 + 3]
    // Line A's top end is at view (30, 85); the arc / copy start there. Nothing near the far crossing above.
    float near = 0, above = 0;
    for (int y = 84; y < 100; y++) for (int x = 31; x <= 40; x++) if (A(x, y) > near) near = A(x, y);
    for (int y = 0; y < 60; y++) for (int x = 0; x < (int)W; x++) if (A(x, y) > above) above = A(x, y);
    XCTAssertGreaterThan(near, 0.2f);
    XCTAssertLessThan(above, 0.01f);
    #undef A
    free(px);
    BKOverlayListFree(L);
}

@end
