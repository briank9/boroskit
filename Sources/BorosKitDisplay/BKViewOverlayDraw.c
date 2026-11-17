// BorosKitDisplay: BKViewOverlayDraw - see BKViewOverlayDraw.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKViewOverlayDraw.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

BKVec2f BKViewMap(const BKViewXf *xf, double x, double y)
{
    return BKV2f((float)(xf->a * x + xf->c * y + xf->tx), (float)(xf->b * x + xf->d * y + xf->ty));
}

// Model points -> view points (small lists on the stack, longer ones on the heap).
static BKVec2f *MapAll(const BKViewXf *xf, const double *xy, uint32_t n, BKVec2f *local, uint32_t localCount)
{
    BKVec2f *v = n <= localCount ? local : (BKVec2f *)malloc(sizeof(BKVec2f) * n);
    for (uint32_t i = 0; v && i < n; i++) v[i] = BKViewMap(xf, xy[2 * i], xy[2 * i + 1]);
    return v;
}

void BKViewDrawLines(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, int how,
                     const BKViewPen *pen, BKOverlayColor color, const BKOverlayColor *colors)
{
    if (!list || !xf || !xy || !pen || n < 2) return;
    BKVec2f local[128];
    BKVec2f *v = MapAll(xf, xy, n, local, 128);
    if (!v) return;
    BKOverlayStroke st;
    memset(&st, 0, sizeof st);
    st.width = pen->width > 1.0f / 64 ? pen->width : 1.0f / 64;
    st.cap = BKOverlayCapButt; st.join = BKOverlayJoinMiter; st.miterLimit = 10;   // as the old overlay drew lines
    st.dashes = pen->dashCount ? pen->dashes : NULL;
    st.dashCount = pen->dashes ? pen->dashCount : 0;
    st.smooth = pen->smooth ? 1 : 0;
    BKOverlaySetIgnoreAlpha(list, pen->opaque ? 1 : 0);
    if (how == BKViewLineSegments) {
        for (uint32_t i = 0; i + 1 < n; i += 2) {
            BKOverlayColor two[2] = { colors ? colors[i] : color, colors ? colors[i + 1] : color };
            BKOverlayStrokePolyline(list, v + i, colors ? two : NULL, 2, 0, &st, two[0]);
        }
    } else {
        BKOverlayStrokePolyline(list, v, colors, n, how == BKViewLineLoop, &st, colors ? colors[0] : color);
    }
    BKOverlaySetIgnoreAlpha(list, 0);
    if (v != local) free(v);
}

void BKViewDrawDots(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, float size, int round,
                    BKOverlayColor color, const BKOverlayColor *colors)
{
    if (!list || !xf || !xy || n == 0 || !(size > 0)) return;
    BKVec2f local[128];
    BKVec2f *v = MapAll(xf, xy, n, local, 128);
    if (!v) return;
    BKOverlayPoints(list, v, colors, n, size, round ? 1 : 0, round ? 1 : 0, color);
    if (v != local) free(v);
}

void BKViewDrawFill(BKOverlayList *list, const BKViewXf *xf, const double *xy, uint32_t n, int rule, int smooth,
                    int opaque, BKOverlayColor color, const BKOverlayColor *colors)
{
    if (!list || !xf || !xy || n < 3) return;
    BKVec2f local[128];
    BKVec2f *v = MapAll(xf, xy, n, local, 128);
    if (!v) return;
    BKOverlaySetIgnoreAlpha(list, opaque ? 1 : 0);
    BKOverlayFillPolygon(list, v, rule == BKOverlayFillFan ? colors : NULL, n, rule, smooth ? 1 : 0, color);
    BKOverlaySetIgnoreAlpha(list, 0);
    if (v != local) free(v);
}

void BKViewDrawPicture(BKOverlayList *list, const BKViewXf *xf, int32_t image, uint32_t imgW, uint32_t imgH,
                       double x, double y, double w, double h, int flipX, int flipY, int crisp, BKOverlayColor color)
{
    if (!list || !xf || image < 0 || imgW == 0 || imgH == 0) return;
    // The picture's top-left pixel corner and its two edges, in model space (mirrored back when flipped).
    double x0 = flipX ? x + w : x, y0 = flipY ? y + h : y;
    double ux = (flipX ? -w : w) / imgW, vy = (flipY ? -h : h) / imgH;   // model units per picture pixel
    BKVec2f o = BKViewMap(xf, x0, y0);
    BKVec2f u = BKV2f((float)(xf->a * ux), (float)(xf->b * ux)), v = BKV2f((float)(xf->c * vy), (float)(xf->d * vy));
    int linear = 1;
    if (crisp) {
        o.x = roundf(o.x); o.y = roundf(o.y);
        linear = 0;
    } else {
        int exact = fabsf(fabsf(u.x) - 1) < 1e-3f && fabsf(fabsf(v.y) - 1) < 1e-3f && fabsf(u.y) < 1e-3f && fabsf(v.x) < 1e-3f &&
                    fabsf(o.x - roundf(o.x)) < 1e-3f && fabsf(o.y - roundf(o.y)) < 1e-3f;
        linear = !exact;
    }
    BKOverlayDrawImage(list, image, o, u, v, linear, color);
}

// ---- Magnifying lens (plan step 6, 2026-11-16) ------------------------------------------------------------
// Sampling follows the usual texture rule: pixel k of a picture covers coordinates k .. k+1, its centre is
// k + 0.5; outside the picture the edge pixel repeats.

uint32_t BKViewLensPictureSize(const BKViewXf *xf, double side)
{
    if (!xf || !(side > 0)) return 1;
    double across = side * sqrt(xf->a * xf->a + xf->b * xf->b);   // the square's top edge in view pixels
    double down = side * sqrt(xf->c * xf->c + xf->d * xf->d);     // its left edge
    double n = ceil(across > down ? across : down);
    if (!(n >= 1)) n = 1;
    if (n > 4096) n = 4096;
    return (uint32_t)n;
}

// One colour channel byte of pixel (px, py), edge repeated.
static inline float LensByte(const uint8_t *p, uint32_t w, uint32_t h, uint32_t stride, uint32_t off, long px, long py)
{
    if (px < 0) px = 0; else if (px >= (long)w) px = (long)w - 1;
    if (py < 0) py = 0; else if (py >= (long)h) py = (long)h - 1;
    return p[((size_t)py * w + (size_t)px) * stride + off];
}

// The picture's value at coordinate (sx, sy): the nearest pixel, or blended from the four around it.
static inline float LensSample(const uint8_t *p, uint32_t w, uint32_t h, uint32_t stride, uint32_t off,
                               double sx, double sy, int linear)
{
    if (!linear) return LensByte(p, w, h, stride, off, (long)floor(sx), (long)floor(sy));
    double fx = sx - 0.5, fy = sy - 0.5;
    long x0 = (long)floor(fx), y0 = (long)floor(fy);
    float tx = (float)(fx - x0), ty = (float)(fy - y0);
    float a = LensByte(p, w, h, stride, off, x0, y0), b = LensByte(p, w, h, stride, off, x0 + 1, y0);
    float c = LensByte(p, w, h, stride, off, x0, y0 + 1), d = LensByte(p, w, h, stride, off, x0 + 1, y0 + 1);
    return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty;
}

int BKViewDrawLens(BKOverlayList *list, const BKViewXf *xf, double x, double y, double side,
                   const uint8_t *zoomed, uint32_t zoomSize, uint32_t redOffset, double from, double to,
                   const uint8_t *mask, uint32_t maskW, uint32_t maskH, int smooth)
{
    if (!list || !xf || !zoomed || !mask || zoomSize == 0 || maskW == 0 || maskH == 0 || redOffset > 1 || !(side > 0))
        return 0;
    uint32_t n = BKViewLensPictureSize(xf, side);
    uint8_t *pic = (uint8_t *)malloc((size_t)n * n * 4);
    if (!pic) return 0;
    double step = (to - from) / n;   // zoomed-picture units per lens pixel
    for (uint32_t j = 0; j < n; j++) {
        double zy = from + (j + 0.5) * step, my = (j + 0.5) * maskH / n;
        uint8_t *row = pic + (size_t)j * n * 4;
        for (uint32_t i = 0; i < n; i++) {
            double zx = from + (i + 0.5) * step, mx = (i + 0.5) * maskW / n;
            float cover = LensSample(mask, maskW, maskH, 1, 0, mx, my, 1);
            uint8_t *o = row + (size_t)i * 4;
            for (uint32_t k = 0; k < 3; k++)
                o[k] = (uint8_t)lrintf(LensSample(zoomed, zoomSize, zoomSize, 4, redOffset + k, zx, zy, smooth));
            o[3] = (uint8_t)lrintf(cover);
        }
    }
    int32_t img = BKOverlayAddImage(list, n, n, BKOverlayImageRGBA8, pic, (size_t)n * 4);
    free(pic);
    if (img < 0) return 0;
    // The lens picture covers the model square exactly, one lens pixel = side / n model units.
    BKVec2f o = BKViewMap(xf, x, y);
    double s = side / n;
    BKVec2f u = BKV2f((float)(xf->a * s), (float)(xf->b * s)), v = BKV2f((float)(xf->c * s), (float)(xf->d * s));
    BKOverlayDrawImage(list, img, o, u, v, 1, (BKOverlayColor){ 1, 1, 1, 1 });
    return 1;
}
