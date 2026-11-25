// Tests for BKThickSlabCore (the 2D viewer's thick slab "VR" picture). Boros 6 (2026-11-24, thickslab).
//
// Original BorosKit code written for this project; contains no third-party code.
// These numbers are the reference a Vulkan / other backend must reproduce.

#import <XCTest/XCTest.h>
#import <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include "BKThickSlabCore.h"

@interface BKThickSlabCoreTests : XCTestCase
@end

@implementation BKThickSlabCoreTests

// The window rule by hand.
- (void)testWindowByteByHand
{
    float lo, hi;
    BKThickSlabWindowEnds(40.0f, 400.0f, &lo, &hi);
    XCTAssertEqual(lo, -160.0f);
    XCTAssertEqual(hi, 240.0f);
    XCTAssertEqual(BKThickSlabWindowByte(-1000.0f, lo, hi), 0);
    XCTAssertEqual(BKThickSlabWindowByte(-160.0f, lo, hi), 0);
    XCTAssertEqual(BKThickSlabWindowByte(240.0f, lo, hi), 255);
    XCTAssertEqual(BKThickSlabWindowByte(3000.0f, lo, hi), 255);
    XCTAssertEqual(BKThickSlabWindowByte(40.0f, lo, hi), 128);   // 127.5 rounds up
    XCTAssertEqual(BKThickSlabWindowByte(NAN, lo, hi), 0);
    XCTAssertEqual(BKThickSlabWindowByte(INFINITY, lo, hi), 255);
    XCTAssertEqual(BKThickSlabWindowByte(-INFINITY, lo, hi), 0);
    // Colour sums 0..255 -> bytes: round half up.
    XCTAssertEqual(BKThickSlabWindowByte(0.49f, 0, 255), 0);
    XCTAssertEqual(BKThickSlabWindowByte(0.5f, 0, 255), 1);
    XCTAssertEqual(BKThickSlabWindowByte(254.4f, 0, 255), 254);
    // Zero-width window = threshold.
    XCTAssertEqual(BKThickSlabWindowByte(5.0f, 5.0f, 5.0f), 255);
    XCTAssertEqual(BKThickSlabWindowByte(4.9f, 5.0f, 5.0f), 0);
    // Reversed window (negative width) maps backwards, like the classic routine.
    XCTAssertEqual(BKThickSlabWindowByte(1.0f, 3.0f, 1.0f), 255);
    XCTAssertEqual(BKThickSlabWindowByte(3.0f, 3.0f, 1.0f), 0);
}

// Apple's float -> byte routine (what the classic view used) is the reference for the window rule: identical bytes
// on many random values over several windows (incl. a very narrow one, where rounding matters most).
- (void)testWindowByteMatchesClassicRoutine
{
    const int n = 1000000;
    float *src = malloc(sizeof(float) * n);
    uint8_t *ref = malloc(n);
    const float levels[] = { 1000.0f, 127.0f, 40.0f, 3.305f, 1023.5f, 1001.1f, -500.0f };
    const float widths[] = { 4000.0f, 256.0f, 400.0f, 0.01f, 4095.0f, 1.2f, 1.0f };
    srand(7);
    for (int k = 0; k < 7; k++) {
        float lo, hi;
        BKThickSlabWindowEnds(levels[k], widths[k], &lo, &hi);
        for (int i = 0; i < n; i++) src[i] = lo - (hi - lo) * 0.2f + (hi - lo) * 1.4f * ((float)rand() / (float)RAND_MAX);
        vImage_Buffer a = { src, 1, (vImagePixelCount)n, sizeof(float) * n };
        vImage_Buffer b = { ref, 1, (vImagePixelCount)n, (size_t)n };
        XCTAssertEqual(vImageConvert_PlanarFtoPlanar8(&a, &b, hi, lo, 0), kvImageNoError);
        int bad = 0;
        for (int i = 0; i < n; i++) if (BKThickSlabWindowByte(src[i], lo, hi) != ref[i]) bad++;
        XCTAssertEqual(bad, 0, @"window %d", k);
    }
    free(src);
    free(ref);
}

- (void)testOpacityTable
{
    float t[256];
    // No points: straight ramp.
    BKThickSlabOpacityTable(NULL, NULL, 0, t);
    XCTAssertEqual(t[0], 0.0f);
    XCTAssertEqualWithAccuracy(t[51], 0.2f, 1e-7);
    XCTAssertEqual(t[255], 1.0f);

    // Points (stored + 1000): (100, 0) (200, 0.8). Added: (0,0) before, (255,1) after.
    double x1[] = { 1100, 1200 }, y1[] = { 0.0, 0.8 };
    BKThickSlabOpacityTable(x1, y1, 2, t);
    XCTAssertEqual(t[0], 0.0f);
    XCTAssertEqual(t[100], 0.0f);
    XCTAssertEqualWithAccuracy(t[150], 0.4f, 1e-7);
    XCTAssertEqualWithAccuracy(t[200], 0.8f, 1e-7);
    XCTAssertEqualWithAccuracy(t[255], 1.0f, 1e-7);
    XCTAssertEqualWithAccuracy(t[230], 0.8 + 0.2 * 30.0 / 55.0, 1e-7);

    // First point at 0: no (0,0) added -> flat from its own value. Last point at 256 -> (255, its value).
    double x2[] = { 1000, 1256 }, y2[] = { 0.5, 0.25 };
    BKThickSlabOpacityTable(x2, y2, 2, t);
    XCTAssertEqual(t[0], 0.5f);
    XCTAssertEqualWithAccuracy(t[128], 0.5 - 0.25 * 128.0 / 255.0, 1e-7);
    XCTAssertEqual(t[255], 0.25f);

    // A later point at the same place replaces the earlier one; a point at 255 is replaced by the end point (255,1).
    double x3[] = { 1050, 1050, 1255, 1100 }, y3[] = { 0.9, 0.1, 0.3, 0.2 };
    BKThickSlabOpacityTable(x3, y3, 4, t);
    XCTAssertEqualWithAccuracy(t[50], 0.1f, 1e-7);
    XCTAssertEqualWithAccuracy(t[25], 0.05f, 1e-7);
    XCTAssertEqualWithAccuracy(t[100], 0.2f, 1e-7);
    XCTAssertEqual(t[255], 1.0f);
}

// A 2 x 1 picture, 3 slices, by hand.
- (void)testCompositeByHand
{
    // Slice values already on 0..255 (window 127.5 / 255 -> low 0, high 255: value v -> byte v).
    const float src[6] = { 255, 0,   255, 128,   0, 255 };
    float op[256], grey[256];
    for (int i = 0; i < 256; i++) op[i] = i == 255 ? 0.5f : (i == 128 ? 0.25f : 0.0f);
    BKThickSlabGreyTable(grey);
    BKThickSlabParams p = { 0 };
    p.width = 2; p.height = 1; p.sliceCount = 3; p.source = src;
    p.windowLow = 0; p.windowHigh = 255;
    p.opacity = op; p.red = grey; p.green = grey; p.blue = grey;

    // Pixel 0 front to back: 255 (0.5) -> 255 (0.5, all that is left) -> stop. Colour 255.
    // Pixel 1: 0 (0) -> 128 (0.25) -> 255 (0.5). Colour 0.25 * 128 + 0.5 * 255 = 159.5 -> 160.
    uint8_t out[8];
    XCTAssertEqual(BKThickSlabRenderRows(&p, 0, 1, out), 0);
    XCTAssertEqual(out[0], 255); XCTAssertEqual(out[1], 255); XCTAssertEqual(out[2], 255); XCTAssertEqual(out[3], 255);
    XCTAssertEqual(out[4], 255); XCTAssertEqual(out[5], 160); XCTAssertEqual(out[6], 160); XCTAssertEqual(out[7], 160);

    // Reversed (mode 5): pixel 1 = 255 (0.5) -> 128 (0.25) -> 0. Colour 127.5 + 32 = 159.5 -> 160 again;
    // pixel 0 = 0 (0) -> 255 (0.5) -> 255 (0.5) = 255.
    p.reverseSlices = 1;
    XCTAssertEqual(BKThickSlabRenderRows(&p, 0, 1, out), 0);
    XCTAssertEqual(out[1], 255); XCTAssertEqual(out[5], 160);

    // Colour table: red only.
    float zero[256] = { 0 };
    p.reverseSlices = 0;
    p.green = zero; p.blue = zero;
    XCTAssertEqual(BKThickSlabRenderRows(&p, 0, 1, out), 0);
    XCTAssertEqual(out[1], 255); XCTAssertEqual(out[2], 0); XCTAssertEqual(out[3], 0);

    // Fused scan: same values, red table for the main scan, blue for the fused one. Pixel 0: 0.5 + 0.5 = 1 -> fits
    // exactly, nothing left; next slice sums 1 > 0 -> shares 0 and stops. Red 127.5 -> 128, blue 128.
    float blendSrc[6] = { 255, 0,   255, 128,   0, 255 };
    p.blendSource = blendSrc; p.blendWindowLow = 0; p.blendWindowHigh = 255;
    p.blendRed = zero; p.blendGreen = zero; p.blendBlue = grey;
    XCTAssertEqual(BKThickSlabRenderRows(&p, 0, 1, out), 0);
    XCTAssertEqual(out[1], 128); XCTAssertEqual(out[2], 0); XCTAssertEqual(out[3], 128);
}

// Bad input writes nothing.
- (void)testBadInput
{
    uint8_t out[4] = { 7, 7, 7, 7 };
    BKThickSlabParams p = { 0 };
    XCTAssertEqual(BKThickSlabRenderRows(&p, 0, 1, out), -1);
    XCTAssertEqual(BKThickSlabRenderRows(NULL, 0, 1, out), -1);
    XCTAssertEqual(out[0], 7);
}

// A straightforward restatement of the classic two-step method (whole slab to bytes with Apple's routine, slices
// reordered, then the per-pixel walk over ALL slices without stopping early) must give the same picture as the core,
// and the core's picture must not depend on how rows are split.
- (void)testMatchesClassicMethodAndSplit
{
    const int w = 37, h = 23, n = 19;   // odd sizes on purpose
    const size_t size = (size_t)w * h;
    float *src = malloc(sizeof(float) * size * n);
    srand(11);
    for (size_t i = 0; i < size * n; i++) src[i] = -1000.0f + 4000.0f * ((float)rand() / (float)RAND_MAX);

    double px[] = { 1040, 1090, 1150, 1210 }, py[] = { 0.0, 0.05, 0.3, 0.6 };
    float op[256], r[256], g[256], b[256];
    BKThickSlabOpacityTable(px, py, 4, op);
    for (int i = 0; i < 256; i++) { r[i] = i; g[i] = (float)((i * 7) % 256); b[i] = 255 - i; }

    for (int reverse = 0; reverse <= 1; reverse++) {
        float lo, hi;
        BKThickSlabWindowEnds(300.0f, 1500.0f, &lo, &hi);

        // Classic method.
        uint8_t *bytes = malloc(size * n), *ordered = malloc(size * n);
        vImage_Buffer a = { src, (vImagePixelCount)(h * n), (vImagePixelCount)w, sizeof(float) * w };
        vImage_Buffer bb = { bytes, (vImagePixelCount)(h * n), (vImagePixelCount)w, (size_t)w };
        vImageConvert_PlanarFtoPlanar8(&a, &bb, hi, lo, 0);
        for (int z = 0; z < n; z++) memcpy(ordered + (size_t)(reverse ? n - 1 - z : z) * size, bytes + (size_t)z * size, size);
        uint8_t *ref = malloc(size * 4);
        for (size_t i = 0; i < size; i++) {
            float tot = 1, cr = 0, cg = 0, cb = 0;
            for (int z = 0; z < n; z++) {
                uint8_t v = ordered[(size_t)z * size + i];
                float o = op[v];
                if (o > tot) o = tot;
                tot -= o;
                cr = fmaf(o, r[v], cr); cg = fmaf(o, g[v], cg); cb = fmaf(o, b[v], cb);
            }
            float c[3] = { cr, cg, cb };
            ref[i * 4] = 255;
            for (int k = 0; k < 3; k++) {
                float t = c[k] + 0.5f;
                ref[i * 4 + 1 + k] = t <= 0 ? 0 : (t >= 255 ? 255 : (uint8_t)t);
            }
        }

        BKThickSlabParams p = { 0 };
        p.width = w; p.height = h; p.sliceCount = n; p.reverseSlices = reverse; p.source = src;
        p.windowLow = lo; p.windowHigh = hi; p.opacity = op; p.red = r; p.green = g; p.blue = b;
        uint8_t *whole = malloc(size * 4), *split = malloc(size * 4);
        XCTAssertEqual(BKThickSlabRenderRows(&p, 0, h, whole), 0);
        for (int row = 0; row < h; row += 5) BKThickSlabRenderRows(&p, row, row + 5, split);
        XCTAssertEqual(memcmp(whole, ref, size * 4), 0, @"reverse %d", reverse);
        XCTAssertEqual(memcmp(whole, split, size * 4), 0, @"reverse %d", reverse);
        free(bytes); free(ordered); free(ref); free(whole); free(split);
    }
    free(src);
}

@end
