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

@end
