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
