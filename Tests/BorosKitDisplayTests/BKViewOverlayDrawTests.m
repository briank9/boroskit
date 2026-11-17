// Tests for BKViewOverlayDraw (the 2D views' own overlays into the draw list), checked with the CPU reference
// rasteriser.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKViewOverlayDraw.h"
#include <stdlib.h>

@interface BKViewOverlayDrawTests : XCTestCase
@end

@implementation BKViewOverlayDrawTests

// Model space = view centred, y down: view = model + (32, 16).
static BKViewXf Centred(void) { BKViewXf x = { 1, 0, 0, 1, 32, 16 }; return x; }

- (void)testLinesDotsFill
{
    const uint32_t W = 64, H = 32;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    BKViewXf xf = Centred();
    BKViewPen pen = { 2, NULL, 0, 0, 0 };
    BKOverlayColor red = { 1, 0, 0, 1 };
    #define A(X, Y) px[((Y) * W + (X)) * 4 + 3]
    double seg[4] = { -20, 0, 20, 0 };
    BKViewDrawLines(L, &xf, seg, 2, BKViewLineSegments, &pen, red, NULL);   // view (12,16) - (52,16)
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(30, 16), 0.9f);
    XCTAssertLessThan(A(30, 12), 0.01f);

    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    float dash[2] = { 4, 4 };
    BKViewPen dashed = { 2, dash, 2, 0, 0 };
    BKViewDrawLines(L, &xf, seg, 2, BKViewLineStrip, &dashed, red, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(13, 16), 0.9f);    // first dash
    XCTAssertLessThan(A(18, 16), 0.01f);      // first gap

    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    double sq[8] = { -10, -5, 10, -5, 10, 5, -10, 5 };
    BKViewDrawFill(L, &xf, sq, 4, BKOverlayFillFan, 0, 0, (BKOverlayColor){ 0, 0, 1, 0.5f }, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertEqualWithAccuracy(A(32, 16), 0.5f, 0.01f);

    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    double dot[2] = { 0, 0 };
    BKViewDrawDots(L, &xf, dot, 1, 6, 1, red, NULL);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(A(32, 16), 0.9f);
    XCTAssertLessThan(A(32, 22), 0.01f);
    #undef A
    free(px);
    BKOverlayListFree(L);
}

// A 4 x 2 mask picture into a rectangle, plain and mirrored back: its first column lands where it should.
- (void)testPicture
{
    const uint32_t W = 16, H = 8;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    uint8_t m[8] = { 255, 0, 0, 0, 255, 0, 0, 0 };            // only column 0 on
    int32_t img = BKOverlayAddImage(L, 4, 2, BKOverlayImageAlpha8, m, 4);
    BKViewXf xf = { 1, 0, 0, 1, 0, 0 };
    BKViewDrawPicture(L, &xf, img, 4, 2, 4, 2, 4, 2, 0, 0, 0, (BKOverlayColor){ 1, 1, 1, 1 });
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(px[(2 * W + 4) * 4 + 3], 0.9f);     // column 0 at view x = 4
    XCTAssertLessThan(px[(2 * W + 5) * 4 + 3], 0.01f);

    // Mirrored view (x -> -x + 16) and the picture mirrored back: column 0 still on the reading-left side.
    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    img = BKOverlayAddImage(L, 4, 2, BKOverlayImageAlpha8, m, 4);
    BKViewXf flip = { -1, 0, 0, 1, 16, 0 };
    BKViewDrawPicture(L, &flip, img, 4, 2, 4, 2, 4, 2, 1, 0, 0, (BKOverlayColor){ 1, 1, 1, 1 });   // model 4..8 -> view 8..12
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(px[(2 * W + 8) * 4 + 3], 0.9f);
    XCTAssertLessThan(px[(2 * W + 11) * 4 + 3], 0.01f);
    free(px);
    BKOverlayListFree(L);
}

// The magnifying lens: zoomed picture (A,R,G,B bytes) left half red / right half blue, mask showing only its left
// half. The lens square covers view (16,0)-(48,32): its left part shows red, its right part nothing; hard blocks
// (smooth 0) keep the colour edge sharp, and the lens picture is one pixel per view pixel.
- (void)testLens
{
    const uint32_t W = 64, H = 32;
    float *px = (float *)calloc(W * H * 4, sizeof(float));
    BKOverlayList *L = BKOverlayListCreate();
    BKViewXf xf = Centred();
    uint8_t zoomed[4 * 4 * 4];
    for (int k = 0; k < 16; k++) {
        int col = k % 4;
        uint8_t *p = zoomed + k * 4;
        p[0] = 0; p[1] = col < 2 ? 255 : 0; p[2] = 0; p[3] = col < 2 ? 0 : 255;   // A, R, G, B
    }
    uint8_t mask[2] = { 255, 0 };
    XCTAssertEqual(BKViewLensPictureSize(&xf, 32), 32u);
    XCTAssertEqual(BKViewDrawLens(L, &xf, -16, -16, 32, zoomed, 4, 1, 0, 4, mask, 2, 1, 0), 1);
    BKOverlayRasterize(L, px, W, H);
    #define P(X, Y, C) px[((Y) * W + (X)) * 4 + (C)]
    XCTAssertGreaterThan(P(18, 16, 3), 0.95f);    // left edge: mask fully open
    XCTAssertGreaterThan(P(18, 16, 0), 0.95f);    // red
    XCTAssertLessThan(P(18, 16, 2), 0.01f);
    XCTAssertLessThan(P(46, 16, 3), 0.05f);       // right edge: masked out
    XCTAssertLessThan(P(10, 16, 3), 0.001f);      // outside the square: nothing
    XCTAssertEqualWithAccuracy(P(32, 16, 3), 0.5f, 0.1f);   // mask half-way across
    // Backwards window (from 4 to 0): the colours swap sides - blue now on the left.
    BKOverlayListReset(L); memset(px, 0, W * H * 4 * sizeof(float));
    XCTAssertEqual(BKViewDrawLens(L, &xf, -16, -16, 32, zoomed, 4, 1, 4, 0, mask, 2, 1, 0), 1);
    BKOverlayRasterize(L, px, W, H);
    XCTAssertGreaterThan(P(18, 16, 2), 0.95f);
    XCTAssertLessThan(P(18, 16, 0), 0.01f);
    // Nothing to draw.
    XCTAssertEqual(BKViewDrawLens(L, &xf, 0, 0, 0, zoomed, 4, 1, 0, 4, mask, 2, 1, 0), 0);
    XCTAssertEqual(BKViewDrawLens(L, &xf, 0, 0, 8, NULL, 4, 1, 0, 4, mask, 2, 1, 0), 0);
    #undef P
    free(px);
    BKOverlayListFree(L);
}

@end
