// BorosKitDisplay: BKROIDraw - see BKROIDraw.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKROIDraw.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define BK_DRAW_PI 3.14159265358979323846   /* own constant: M_PI is not part of strict C99 */

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

// Handles that show whenever the ROI is selected or being drawn (rectangle, oval).
static void BoxHandles(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n)
{
    if (!ctx->highlight || !(ctx->selected || ctx->drawing)) return;
    float k = ctx->backing > 0 ? ctx->backing : 1.0f;
    const BKOverlayColor blue = { 0.5f, 0.5f, 1.0f, 1.0f };
    BKROIDrawDots(list, ctx, pts, n, (k + sqrtf(ctx->thick)) * 3.5f * k, blue);
}

void BKROIDrawRect(BKOverlayList *list, const BKROIDrawContext *ctx, double x, double y, double w, double h)
{
    if (!list || !ctx) return;
    float k = ctx->backing > 0 ? ctx->backing : 1.0f;
    BKROIPoint c[4] = { { x, y }, { x, y + h }, { x + w, y + h }, { x + w, y } };
    BKROIDrawLine(list, ctx, c, 4, 1, ctx->thick * k, ctx->color);
    BKROIDrawDots(list, ctx, c, 4, ctx->thick * k, ctx->color);
    BoxHandles(list, ctx, c, 4);
}

void BKROIDrawOval(BKOverlayList *list, const BKROIDrawContext *ctx, double cx, double cy, double rw, double rh,
                   int centreDot)
{
    if (!list || !ctx) return;
    float k = ctx->backing > 0 ? ctx->backing : 1.0f;
    rw = fabs(rw); rh = fabs(rh);
    int n = (int)((rh + rw) * 1.5 * ctx->scale);
    if (n > 0) {
        BKROIPoint *p = (BKROIPoint *)malloc(sizeof(BKROIPoint) * ((size_t)n + 1));
        if (p) {
            for (int i = 0; i < n; i++) {
                float angle = (float)((double)(i * 2) * BK_DRAW_PI / n);   // held as a float, as the old drawing
                p[i].x = cx + rw * cos((double)angle);
                p[i].y = cy + rh * sin((double)angle);
            }
            BKROIDrawLine(list, ctx, p, (uint32_t)n, 1, ctx->thick * k, ctx->color);
            uint32_t dots = (uint32_t)n;
            if (centreDot) { p[n].x = cx; p[n].y = cy; dots++; }
            BKROIDrawDots(list, ctx, p, dots, ctx->thick * k, ctx->color);
            free(p);
        }
    } else if (centreDot) {
        BKROIPoint c = { cx, cy };
        BKROIDrawDots(list, ctx, &c, 1, ctx->thick * k, ctx->color);
    }
    BKROIPoint box[5] = { { cx - rw, cy - rh }, { cx - rw, cy + rh }, { cx + rw, cy + rh }, { cx + rw, cy - rh }, { cx, cy } };
    BoxHandles(list, ctx, box, 5);
}

void BKROIDrawArrow(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIPoint a, BKROIPoint b,
                    double spacingX, double spacingY, float along)
{
    if (!list || !ctx) return;
    float k = ctx->backing > 0 ? ctx->backing : 1.0f;
    double s = ctx->scale != 0 ? ctx->scale : 1.0;
    float t = ctx->thick * 0.5f;
    if (t > 5) t = 5;
    const float degree = (float)(BK_DRAW_PI / 180.0f);
    int known = spacingX != 0 && spacingY != 0;
    double ratio = known ? spacingX / spacingY : 1.0;          // y stretch applied to offsets from the tip

    // Directions are worked out in the zoomed image space (image x scale), as the old drawing did.
    double ax = a.x * s, ay = a.y * s, bx = b.x * s, by = b.y * s;
    float slide;
    if ((by - ay) == 0) slide = (float)((bx - ax) / -0.001);
    else slide = (float)((bx - ax) / ((by - ay) * (known ? spacingY / spacingX : 1.0)));
    float head = 25.0f * (t * k / 3.0f);
    float turn = atanf(slide) / degree;                         // the arrow's direction, in degrees
    int down = (by - ay) > 0;
    double sign = down ? 1.0 : -1.0;

    // Shaft start, (head + 13 t) from the tip.
    float L1 = head + t * k * 13, ang = 90 - turn;
    double sx = ax + sign * L1 * cos(ang * degree), sy = ay + sign * L1 * sin(ang * degree) * ratio;
    BKROIPoint shaft[2] = { { sx / s, sy / s }, b };
    BKROIDrawLine(list, ctx, shaft, 2, 0, t * 2 * k, ctx->color);
    BKROIDrawDots(list, ctx, shaft, 2, t * 2 * k, ctx->color);

    // Head: back corners (head + 15 t) away, 80 and 100 degrees off (+/- t degrees), turned 180 when the
    // arrow points up.
    float L2 = head + t * k * 15, base = down ? 0.0f : 180.0f;
    float a1 = base + 80 - turn - t * k, a2 = base + 100 - turn + t * k;
    BKROIPoint tri[3] = {
        { (ax + L2 * cos(a1 * degree)) / s, (ay + L2 * sin(a1 * degree) * ratio) / s },
        { (ax + L2 * cos(a2 * degree)) / s, (ay + L2 * sin(a2 * degree) * ratio) / s },
        a };
    BKVec2f v[3] = { BKROIDrawMap(ctx, tri[0]), BKROIDrawMap(ctx, tri[1]), BKROIDrawMap(ctx, tri[2]) };
    BKOverlayFillTriangles(list, v, NULL, 3, ctx->color);

    BKROIPoint ends[2] = { a, b };
    BKROIDrawHandles(list, ctx, ends, 2, sqrtf(t) * 3.0f * k);
    if (along >= 0) {
        BKROIPoint m = { a.x + along * (b.x - a.x), a.y + along * (b.y - a.y) };
        const BKOverlayColor red = { 1.0f, 0.0f, 0.0f, 1.0f };
        BKROIDrawDots(list, ctx, &m, 1, (k + sqrtf(t)) * 3.5f * k, red);
    }
}
