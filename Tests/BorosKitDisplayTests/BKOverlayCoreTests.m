// Tests for BKOverlayCore (the 2D overlay engine's plain-C core), drawn with its CPU reference
// rasteriser - the same pixels any GPU backend (Metal now, Vulkan later) must produce.
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKOverlayCore.h"

@interface BKOverlayCoreTests : XCTestCase
@end

static const BKOverlayColor kWhite = { 1, 1, 1, 1 };

// What: renders `list` on a black width x height picture; returns the alpha of each pixel (row 0 = top).
static float *Render(BKOverlayList *list, uint32_t w, uint32_t h)
{
    float *rgba = calloc((size_t)w * h * 4, sizeof(float));
    BKOverlayRasterize(list, rgba, w, h);
    float *a = calloc((size_t)w * h, sizeof(float));
    for (size_t i = 0; i < (size_t)w * h; i++) a[i] = rgba[i * 4 + 3];
    free(rgba);
    return a;
}

static BKOverlayStroke Stroke(float width, int smooth)
{
    BKOverlayStroke s;
    memset(&s, 0, sizeof(s));
    s.width = width; s.cap = BKOverlayCapButt; s.join = BKOverlayJoinMiter; s.miterLimit = 10; s.smooth = smooth;
    return s;
}

@implementation BKOverlayCoreTests

- (void)testVertexLayoutIsStd430Friendly
{
    XCTAssertEqual(sizeof(BKOverlayVertex), (size_t)32);   // 8 floats, no padding: same in GLSL std430
}

// A 2-pixel horizontal line covers exactly the two pixel rows it spans, between its ends (butt caps).
- (void)testSolidLineCoversExactPixels
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s = Stroke(2, 0);
    BKVec2f p[2] = { {2, 5}, {12, 5} };
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);
    float *a = Render(l, 16, 10);
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 16; x++) {
            float expect = (y == 4 || y == 5) && x >= 2 && x < 12 ? 1 : 0;
            XCTAssertEqualWithAccuracy(a[y * 16 + x], expect, 1e-5, @"pixel %d,%d", x, y);
        }
    free(a); BKOverlayListFree(l);
}

// Smooth: full alpha in the middle, about half on the pixel rows the true edge passes through.
- (void)testSmoothLineFadesOverOnePixel
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s = Stroke(3, 1);
    BKVec2f p[2] = { {2, 10}, {28, 10} };   // edges at y = 8.5 and 11.5
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);
    float *a = Render(l, 32, 20);
    XCTAssertEqualWithAccuracy(a[10 * 32 + 15], 1, 1e-4);   // centre row (centre y 10.5)
    XCTAssertEqualWithAccuracy(a[9 * 32 + 15], 1, 1e-4);    // centre 9.5: 1 px inside the edge 8.5
    XCTAssertEqualWithAccuracy(a[8 * 32 + 15], 0.5, 0.05);  // centre 8.5: on the edge
    XCTAssertEqualWithAccuracy(a[11 * 32 + 15], 0.5, 0.05); // centre 11.5: on the edge
    XCTAssertEqualWithAccuracy(a[6 * 32 + 15], 0, 1e-5);
    free(a); BKOverlayListFree(l);
}

// A right-angle corner with a miter join fills the outer corner square.
- (void)testMiterJoinFillsCorner
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s = Stroke(4, 0);
    BKVec2f p[3] = { {4, 10}, {20, 10}, {20, 24} };
    BKOverlayStrokePolyline(l, p, NULL, 3, 0, &s, kWhite);
    float *a = Render(l, 32, 32);
    XCTAssertEqualWithAccuracy(a[8 * 32 + 21], 1, 1e-5);   // outer corner (x 21, y 8): inside the miter square
    XCTAssertEqualWithAccuracy(a[9 * 32 + 19], 1, 1e-5);
    XCTAssertEqualWithAccuracy(a[13 * 32 + 21], 1, 1e-5);  // down the vertical piece
    XCTAssertEqualWithAccuracy(a[13 * 32 + 15], 0, 1e-5);  // inside the bend, off the line
    // Bevel instead: the outermost corner pixel is cut off.
    BKOverlayListReset(l);
    s.join = BKOverlayJoinBevel;
    BKOverlayStrokePolyline(l, p, NULL, 3, 0, &s, kWhite);
    float *b = Render(l, 32, 32);
    XCTAssertEqualWithAccuracy(b[8 * 32 + 21], 0, 1e-5);
    free(a); free(b); BKOverlayListFree(l);
}

// Dashes 3 on / 2 off along a horizontal line.
- (void)testDashes
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s = Stroke(2, 0);
    float d[2] = { 3, 2 };
    s.dashes = d; s.dashCount = 2;
    BKVec2f p[2] = { {0, 4}, {20, 4} };
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);
    float *a = Render(l, 24, 8);
    for (int x = 0; x < 20; x++) {
        float expect = (x % 5) < 3 ? 1 : 0;
        XCTAssertEqualWithAccuracy(a[4 * 24 + x], expect, 1e-5, @"x %d", x);
    }
    free(a); BKOverlayListFree(l);
}

// Fan fill (OpenGL GL_POLYGON) of a square; even-odd fill of a U shape leaves the notch empty; a
// self-crossing bow tie by even-odd has two filled triangles and an empty middle above/below the cross.
- (void)testFills
{
    BKOverlayList *l = BKOverlayListCreate();
    BKVec2f sq[4] = { {2, 2}, {10, 2}, {10, 8}, {2, 8} };
    BKOverlayFillPolygon(l, sq, NULL, 4, BKOverlayFillFan, 0, kWhite);
    float *a = Render(l, 16, 12);
    for (int y = 0; y < 12; y++)
        for (int x = 0; x < 16; x++)
            XCTAssertEqualWithAccuracy(a[y * 16 + x], (x >= 2 && x < 10 && y >= 2 && y < 8) ? 1 : 0, 1e-5);
    free(a);
    BKOverlayListReset(l);
    BKVec2f u[8] = { {2, 2}, {6, 2}, {6, 10}, {10, 10}, {10, 2}, {14, 2}, {14, 14}, {2, 14} };
    BKOverlayFillPolygon(l, u, NULL, 8, BKOverlayFillEvenOdd, 0, kWhite);
    float *b = Render(l, 16, 16);
    XCTAssertEqualWithAccuracy(b[5 * 16 + 8], 0, 1e-5);   // the notch
    XCTAssertEqualWithAccuracy(b[5 * 16 + 4], 1, 1e-5);   // left arm
    XCTAssertEqualWithAccuracy(b[12 * 16 + 8], 1, 1e-5);  // bottom bar
    free(b);
    BKOverlayListReset(l);
    BKVec2f bow[4] = { {2, 2}, {14, 14}, {14, 2}, {2, 14} };
    BKOverlayFillPolygon(l, bow, NULL, 4, BKOverlayFillEvenOdd, 0, kWhite);
    float *c = Render(l, 16, 16);
    XCTAssertEqualWithAccuracy(c[8 * 16 + 3], 1, 1e-5);   // left triangle
    XCTAssertEqualWithAccuracy(c[3 * 16 + 8], 0, 1e-5);   // above the crossing: outside
    free(c);
    BKOverlayListFree(l);
}

// Square dots of size 3 cover 3 x 3 pixels around a pixel-centre point.
- (void)testSquarePoints
{
    BKOverlayList *l = BKOverlayListCreate();
    BKVec2f p[1] = { {5.5f, 5.5f} };
    BKOverlayPoints(l, p, NULL, 1, 3, 0, 0, kWhite);
    float *a = Render(l, 12, 12);
    int covered = 0;
    for (int i = 0; i < 144; i++) covered += a[i] > 0.5f;
    XCTAssertEqual(covered, 9);
    XCTAssertEqualWithAccuracy(a[4 * 12 + 4], 1, 1e-5);
    XCTAssertEqualWithAccuracy(a[6 * 12 + 6], 1, 1e-5);
    free(a); BKOverlayListFree(l);
}

// A 2 x 2 RGBA image drawn 3x larger (nearest) gives 3 x 3 blocks; a mask is drawn in the tint colour.
- (void)testImagesAndMasks
{
    BKOverlayList *l = BKOverlayListCreate();
    uint8_t px[16] = { 255, 0, 0, 255,   0, 255, 0, 255,
                       0, 0, 255, 255,   255, 255, 255, 0 };
    int32_t img = BKOverlayAddImage(l, 2, 2, BKOverlayImageRGBA8, px, 8);
    XCTAssertEqual(img, 0);
    BKOverlayDrawImage(l, img, BKV2f(1, 1), BKV2f(3, 0), BKV2f(0, 3), 0, kWhite);
    float *rgba = calloc(8 * 8 * 4, sizeof(float));
    BKOverlayRasterize(l, rgba, 8, 8);
    #define AT(X, Y, K) rgba[((Y) * 8 + (X)) * 4 + (K)]
    XCTAssertEqualWithAccuracy(AT(2, 2, 0), 1, 1e-5);   // red block
    XCTAssertEqualWithAccuracy(AT(5, 2, 1), 1, 1e-5);   // green block
    XCTAssertEqualWithAccuracy(AT(2, 5, 2), 1, 1e-5);   // blue block
    XCTAssertEqualWithAccuracy(AT(5, 5, 3), 0, 1e-5);   // transparent block
    free(rgba);
    BKOverlayListReset(l);
    uint8_t mask[4] = { 255, 0, 128, 255 };
    int32_t m = BKOverlayAddImage(l, 2, 2, BKOverlayImageAlpha8, mask, 2);
    BKOverlayColor tint = { 1, 0.5f, 0, 1 };
    BKOverlayDrawImage(l, m, BKV2f(0, 0), BKV2f(1, 0), BKV2f(0, 1), 0, tint);
    float *r2 = calloc(4 * 4 * 4, sizeof(float));
    BKOverlayRasterize(l, r2, 4, 4);
    XCTAssertEqualWithAccuracy(r2[(0 * 4 + 0) * 4 + 1], 0.5, 1e-5);       // tint green, full mask
    XCTAssertEqualWithAccuracy(r2[(0 * 4 + 1) * 4 + 3], 0, 1e-5);         // mask 0
    XCTAssertEqualWithAccuracy(r2[(1 * 4 + 0) * 4 + 3], 128 / 255.0, 1e-5);
    #undef AT
    free(r2); BKOverlayListFree(l);
}

// Clip rectangle: nothing outside it changes; same-state items share one command, images start another.
- (void)testClipAndCommands
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlaySetClip(l, 0, 0, 5, 20);
    BKOverlayStroke s = Stroke(2, 0);
    BKVec2f p[2] = { {0, 5}, {20, 5} };
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);
    float *a = Render(l, 20, 10);
    XCTAssertEqualWithAccuracy(a[5 * 20 + 3], 1, 1e-5);
    XCTAssertEqualWithAccuracy(a[5 * 20 + 7], 0, 1e-5);
    free(a);
    BKOverlaySetClip(l, 0, 0, 0, 0);
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);
    BKOverlayStrokePolyline(l, p, NULL, 2, 0, &s, kWhite);   // joins the previous command
    uint8_t px[4] = { 255, 255, 255, 255 };
    BKOverlayDrawImage(l, BKOverlayAddImage(l, 1, 1, BKOverlayImageRGBA8, px, 4), BKV2f(0, 0), BKV2f(1, 0), BKV2f(0, 1), 0, kWhite);
    uint32_t n = 0;
    BKOverlayListCommands(l, &n);
    XCTAssertEqual(n, (uint32_t)3);   // clipped stroke, two unclipped strokes, image
    XCTAssertEqual(BKOverlayListError(l), 0);
    BKOverlayListFree(l);
}

- (void)testBadInputIsSkipped
{
    BKOverlayList *l = BKOverlayListCreate();
    BKOverlayStroke s = Stroke(1, 1);
    BKOverlayStrokePolyline(l, NULL, NULL, 3, 0, &s, kWhite);
    XCTAssertEqual(BKOverlayListError(l), 2);
    BKVec2f nanPts[3] = { {NAN, 1}, {1, 1}, {1, 1} };   // one bad point, one repeat: nothing to draw
    BKOverlayListReset(l);
    BKOverlayStrokePolyline(l, nanPts, NULL, 3, 0, &s, kWhite);
    uint32_t v = 0;
    BKOverlayListVertices(l, &v);
    XCTAssertEqual(v, (uint32_t)0);
    XCTAssertEqual(BKOverlayAddImage(l, 0, 0, BKOverlayImageRGBA8, NULL, 0), -1);
    BKOverlayListFree(l);
}

@end
