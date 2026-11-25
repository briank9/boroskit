// BorosKitRender: BKThickSlabCore - see BKThickSlabCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-24, thickslab): the 2D viewer's thick slab "VR" picture without VTK.

#include "BKThickSlabCore.h"

#include <math.h>
#include <string.h>

void BKThickSlabWindowEnds(float level, float width, float *outLow, float *outHigh)
{
    // Same float operations as the viewer (level +- width / 2), so the ends are identical.
    float half = width / 2;
    if (outLow) *outLow = level - half;
    if (outHigh) *outHigh = level + half;
}

uint8_t BKThickSlabWindowByte(float value, float low, float high)
{
    if (value != value) return 0;                       // not a number -> black
    if (high == low) return value >= low ? 255 : 0;     // zero-width window: a plain threshold
    // What: value * scale + (offset + 0.5) as ONE fused multiply-add, then clamp and keep the whole part.
    // Why the fused form: it reproduces the classic routine's bytes exactly (rounding happens once).
    // Separate statements so no compiler fuses anything else differently.
    float scale = 255.0f / (high - low);
    float offset = -low * scale;
    float offsetHalf = offset + 0.5f;
    float t = fmaf(value, scale, offsetHalf);
    if (t <= 0.0f) return 0;
    if (t >= 255.0f) return 255;
    return (uint8_t)t;
}

// ---- opacity curve ----------------------------------------------------------------------------------------------

// The curve's points, kept sorted by position; a point at an existing position replaces the old one.
typedef struct BKTSCurve {
    double x[260], y[260];
    int32_t n;
} BKTSCurve;

static void BKTSCurveAdd(BKTSCurve *c, double x, double y)
{
    // Replace a point at the same position (it is removed, then the new one is placed in order).
    for (int32_t i = 0; i < c->n; i++) {
        if (c->x[i] == x) {
            memmove(&c->x[i], &c->x[i + 1], (size_t)(c->n - i - 1) * sizeof(double));
            memmove(&c->y[i], &c->y[i + 1], (size_t)(c->n - i - 1) * sizeof(double));
            c->n--;
            break;
        }
    }
    if (c->n >= (int32_t)(sizeof(c->x) / sizeof(c->x[0]))) return;   // more points than any real curve: ignore
    int32_t at = c->n;
    while (at > 0 && c->x[at - 1] > x) at--;
    memmove(&c->x[at + 1], &c->x[at], (size_t)(c->n - at) * sizeof(double));
    memmove(&c->y[at + 1], &c->y[at], (size_t)(c->n - at) * sizeof(double));
    c->x[at] = x;
    c->y[at] = y;
    c->n++;
}

static double BKTSCurveValue(const BKTSCurve *c, double x)
{
    if (c->n <= 0) return 0.0;
    if (x <= c->x[0]) return c->y[0];                   // flat before the first point
    if (x >= c->x[c->n - 1]) return c->y[c->n - 1];     // flat after the last point
    int32_t i = 1;
    while (i < c->n - 1 && c->x[i] <= x) i++;           // first point to the right of x
    double x1 = c->x[i - 1], x2 = c->x[i], y1 = c->y[i - 1], y2 = c->y[i];
    double s = (x - x1) / (x2 - x1);
    // Straight line between the two points; two separate products so no compiler fuses them differently.
    double a = (1.0 - s) * y1;
    double b = s * y2;
    return a + b;
}

void BKThickSlabOpacityTable(const double *xStored, const double *y, int32_t count, float out[256])
{
    if (!out) return;
    if (count < 0 || !xStored || !y) count = 0;
    // A real opacity curve has a handful of points; anything above 256 cannot fit the table's resolution anyway.
    if (count > 256) count = 256;

    BKTSCurve curve;
    curve.n = 0;
    if (count == 0) {
        BKTSCurveAdd(&curve, 0.0, 0.0);
        BKTSCurveAdd(&curve, 255.0, 1.0);
    } else {
        // Classic end rules (header comment): positions are stored + 1000.
        double lastX = 0.0, lastY = 0.0;
        if (xStored[0] - 1000.0 != 0.0) BKTSCurveAdd(&curve, 0.0, 0.0);
        for (int32_t i = 0; i < count; i++) {
            lastX = xStored[i] - 1000.0;
            lastY = y[i];
            BKTSCurveAdd(&curve, lastX, lastY);
        }
        if (lastX != 256.0) BKTSCurveAdd(&curve, 255.0, 1.0);
        else BKTSCurveAdd(&curve, 255.0, lastY);
    }
    for (int32_t i = 0; i < 256; i++) out[i] = (float)BKTSCurveValue(&curve, (double)i);
}

void BKThickSlabGreyTable(float out[256])
{
    if (!out) return;
    for (int32_t i = 0; i < 256; i++) out[i] = (float)i;
}

// ---- picture ----------------------------------------------------------------------------------------------------

void BKThickSlabCompositePixel(const BKThickSlabParams *p, size_t pixelIndex, float outRGB[3])
{
    const size_t sliceSize = (size_t)p->width * (size_t)p->height;
    const int32_t n = p->sliceCount;
    float r = 0.0f, g = 0.0f, b = 0.0f;
    float remaining = 1.0f;

    for (int32_t k = 0; k < n; k++) {
        // k = position in the walk (0 = in front); z = slice in memory.
        int32_t z = p->reverseSlices ? (n - 1 - k) : k;
        size_t at = (size_t)z * sliceSize + pixelIndex;
        uint8_t v = BKThickSlabWindowByte(p->source[at], p->windowLow, p->windowHigh);
        float o = p->opacity[v];

        if (p->blendSource) {
            uint8_t vb = BKThickSlabWindowByte(p->blendSource[at], p->blendWindowLow, p->blendWindowHigh);
            float ob = p->opacity[vb];
            float sum = o + ob;
            int32_t last = 0;
            if (sum > remaining) {
                // Both scans together want more than is left: share what is left, then stop.
                float share = remaining / sum;
                o *= share;
                ob *= share;
                last = 1;
            } else {
                remaining -= sum;
            }
            float mr = p->red[v] * o, mg = p->green[v] * o, mb = p->blue[v] * o;
            r += fmaf(p->blendRed[vb], ob, mr);
            g += fmaf(p->blendGreen[vb], ob, mg);
            b += fmaf(p->blendBlue[vb], ob, mb);
            if (last) break;
        } else {
            if (o > remaining) o = remaining;
            remaining -= o;
            r = fmaf(o, p->red[v], r);
            g = fmaf(o, p->green[v], g);
            b = fmaf(o, p->blue[v], b);
            // Nothing left to add: the rest of the slab cannot change this pixel.
            if (remaining <= 0.0f) break;
        }
    }
    outRGB[0] = r;
    outRGB[1] = g;
    outRGB[2] = b;
}

int32_t BKThickSlabRenderRows(const BKThickSlabParams *p, int32_t rowBegin, int32_t rowEnd, uint8_t *outARGB)
{
    if (!p || !outARGB || !p->source || !p->opacity || !p->red || !p->green || !p->blue) return -1;
    if (p->width <= 0 || p->height <= 0 || p->sliceCount <= 0) return -1;
    if (p->blendSource && (!p->blendRed || !p->blendGreen || !p->blendBlue)) return -1;
    if (rowBegin < 0) rowBegin = 0;
    if (rowEnd > p->height) rowEnd = p->height;

    for (int32_t row = rowBegin; row < rowEnd; row++) {
        size_t first = (size_t)row * (size_t)p->width;
        for (int32_t col = 0; col < p->width; col++) {
            size_t i = first + (size_t)col;
            float rgb[3];
            BKThickSlabCompositePixel(p, i, rgb);
            uint8_t *px = outARGB + i * 4;
            px[0] = 255;
            px[1] = BKThickSlabWindowByte(rgb[0], 0.0f, 255.0f);
            px[2] = BKThickSlabWindowByte(rgb[1], 0.0f, 255.0f);
            px[3] = BKThickSlabWindowByte(rgb[2], 0.0f, 255.0f);
        }
    }
    return 0;
}
