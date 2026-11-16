// BorosKitDisplay: BKROIDraw - see BKROIDraw.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKROIDraw.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

BKVec2f BKROIDrawMap(const BKROIDrawContext *ctx, BKROIPoint p)
{
    const BKROIDrawTransform *t = &ctx->xf;
    return BKV2f((float)(t->a * p.x + t->c * p.y + t->tx), (float)(t->b * p.x + t->d * p.y + t->ty));
}

// Image points -> view points (small lists on the stack, longer ones on the heap).
static BKVec2f *MapAll(const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n, BKVec2f *local, uint32_t localCount)
{
    BKVec2f *v = n <= localCount ? local : (BKVec2f *)malloc(sizeof(BKVec2f) * n);
    for (uint32_t i = 0; v && i < n; i++) v[i] = BKROIDrawMap(ctx, pts[i]);
    return v;
}

void BKROIDrawLine(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   int closed, float width, BKOverlayColor color)
{
    if (!list || !ctx || !pts || n < 2) return;
    BKVec2f local[64];
    BKVec2f *v = MapAll(ctx, pts, n, local, 64);
    if (!v) return;
    BKOverlayStroke st;
    memset(&st, 0, sizeof st);
    st.width = width > 1.0f / 64 ? width : 1.0f / 64;
    st.cap = BKOverlayCapButt; st.join = BKOverlayJoinMiter; st.miterLimit = 10;   // as the old overlay drew lines
    st.smooth = 1;
    BKOverlayStrokePolyline(list, v, NULL, n, closed, &st, color);
    if (v != local) free(v);
}

void BKROIDrawDots(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   float size, BKOverlayColor color)
{
    if (!list || !ctx || !pts || n == 0 || !(size > 0)) return;
    BKVec2f local[64];
    BKVec2f *v = MapAll(ctx, pts, n, local, 64);
    if (!v) return;
    BKOverlayPoints(list, v, NULL, n, size, 1, 1, color);   // round, anti-aliased
    if (v != local) free(v);
}

void BKROIDrawHandles(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                      float size)
{
    if (!list || !ctx || !pts || !ctx->highlight) return;
    const BKOverlayColor hot = { 1.0f, 0.2f, 0.2f, 1.0f }, normal = { 0.5f, 0.5f, 1.0f, 1.0f };
    for (uint32_t i = 0; i < n; i++) {
        int isHot = (int32_t)i == ctx->hotA || (int32_t)i == ctx->hotB;
        if (!isHot && !ctx->selected) continue;
        BKROIDrawDots(list, ctx, &pts[i], 1, size, isHot ? hot : normal);
    }
}

void BKROIDrawLength(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                     int cobbHighlight, float along)
{
    if (!list || !ctx || !pts || n == 0) return;
    float k = ctx->backing > 0 ? ctx->backing : 1.0f;
    if (cobbHighlight) {
        const BKOverlayColor yellow = { 1.0f, 1.0f, 0.0f, 0.5f };
        BKROIDrawLine(list, ctx, pts, n, 0, ctx->thick * 3.0f * k, yellow);
    }
    BKROIDrawLine(list, ctx, pts, n, 0, ctx->thick * k, ctx->color);
    BKROIDrawDots(list, ctx, pts, n, ctx->thick * k, ctx->color);
    BKROIDrawHandles(list, ctx, pts, n, sqrtf(ctx->thick) * 3.0f * k);
    if (along >= 0 && n >= 2) {
        // The marker sits on the line from point 0 towards point 1, `along` of its length.
        BKROIPoint m = { pts[0].x + along * (pts[1].x - pts[0].x), pts[0].y + along * (pts[1].y - pts[0].y) };
        const BKOverlayColor red = { 1.0f, 0.0f, 0.0f, 1.0f };
        BKROIDrawDots(list, ctx, &m, 1, (k + sqrtf(ctx->thick)) * 3.5f * k, red);
    }
}
