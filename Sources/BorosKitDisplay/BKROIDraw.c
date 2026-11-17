// BorosKitDisplay: BKROIDraw - see BKROIDraw.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKROIDraw.h"
#include "BKAngleCore.h"
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

// ======================================================================================================
// Second batch (2026-11-16, plan step 6). VULKAN: safe to translate directly (plain C99, draw list only).
// ======================================================================================================

static float Backing(const BKROIDrawContext *ctx) { return ctx->backing > 0 ? ctx->backing : 1.0f; }
static double Zoom(const BKROIDrawContext *ctx) { return ctx->scale != 0 ? ctx->scale : 1.0; }

// Stroke settings shared by the kinds below (butt caps, mitre joins, soft edge - as the old smooth lines).
static BKOverlayStroke Stroke(float width, int smooth)
{
    BKOverlayStroke st;
    memset(&st, 0, sizeof st);
    st.width = width > 1.0f / 64 ? width : 1.0f / 64;
    st.cap = BKOverlayCapButt; st.join = BKOverlayJoinMiter; st.miterLimit = 10;
    st.smooth = smooth;
    return st;
}

void BKROIDrawAllHandles(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                         const uint8_t *flags, float size)
{
    if (!list || !ctx || !pts || !ctx->highlight || !(ctx->selected || ctx->drawing)) return;
    const BKOverlayColor hot = { 1.0f, 0.2f, 0.2f, 1.0f }, near = { 1.0f, 0.0f, 1.0f, 1.0f }, normal = { 0.5f, 0.5f, 1.0f, 1.0f };
    for (uint32_t i = 0; i < n; i++) {
        uint8_t f = flags ? flags[i] : 0;
        if (f & BKROIPointSkip) continue;
        BKOverlayColor c = normal;
        if (ctx->selected && ((int32_t)i == ctx->hotA || (int32_t)i == ctx->hotB)) c = hot;
        else if (ctx->drawing && (f & BKROIPointNearMouse)) c = near;
        BKROIDrawDots(list, ctx, &pts[i], 1, size, c);
    }
}

// The arc marking an angle at `corner` between rays towards ta / tb, worked out in the zoomed image space
// (image x zoom, where the old code measured the 25-unit radius), drawn `width` wide in `color`.
static void AngleArc(BKOverlayList *list, const BKROIDrawContext *ctx, BKVec2f corner, BKVec2f ta, BKVec2f tb,
                     float shorterArm, float width, BKOverlayColor color)
{
    double s = Zoom(ctx);
    float radius = BKAngleArcRadius(shorterArm, shorterArm, 25.0f * Backing(ctx));
    BKVec2f arc[128];
    uint32_t n = BKAngleArcPoints(corner, ta, tb, radius, 2.0f, arc, 128);
    if (n < 2) return;
    BKROIPoint p[128];
    for (uint32_t i = 0; i < n; i++) { p[i].x = arc[i].x / s; p[i].y = arc[i].y / s; }
    BKROIDrawLine(list, ctx, p, n, 0, width, color);
}

static BKVec2f ZoomPt(const BKROIDrawContext *ctx, BKROIPoint p)
{
    double s = Zoom(ctx);
    return BKV2f((float)(p.x * s), (float)(p.y * s));
}

void BKROIDrawPolygon(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *curve, uint32_t nCurve,
                      const BKROIPoint *pts, uint32_t n, int kind, int closeHint, const uint8_t *flags)
{
    if (!list || !ctx) return;
    float k = Backing(ctx);
    float w = ctx->thick * (ctx->drawing ? 2.0f : 1.0f) * k;
    if (curve && nCurve >= 1) {
        int closed = kind == BKROIPolyClosed && !ctx->drawing;
        if (nCurve >= 2) BKROIDrawLine(list, ctx, curve, nCurve, closed, w, ctx->color);
        if (kind == BKROIPolyAngle && pts && n == 3) {
            BKVec2f a = ZoomPt(ctx, pts[0]), c = ZoomPt(ctx, pts[1]), b = ZoomPt(ctx, pts[2]);
            float la = hypotf(a.x - c.x, a.y - c.y), lb = hypotf(b.x - c.x, b.y - c.y);
            AngleArc(list, ctx, c, a, b, la < lb ? la : lb, w, ctx->color);
        }
        if (kind == BKROIPolyOpen && closeHint && nCurve >= 2) {
            BKOverlayColor faint = ctx->color;
            faint.a *= 0.25f;
            BKROIPoint ends[2] = { curve[0], curve[nCurve - 1] };
            BKROIDrawLine(list, ctx, ends, 2, 0, w, faint);
        }
        BKROIDrawDots(list, ctx, curve, nCurve, w, ctx->color);
    }
    float hs = (k + sqrtf(ctx->thick)) * 3.5f * k;
    BKROIDrawAllHandles(list, ctx, pts, n, flags, hs);
    if (pts && ctx->hotB >= 0 && (uint32_t)ctx->hotB < n) {
        const BKOverlayColor magenta = { 1.0f, 0.0f, 1.0f, 1.0f };
        BKROIDrawDots(list, ctx, &pts[ctx->hotB], 1, hs, magenta);
    }
}

void BKROIDrawDynamicAngle(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                           const uint8_t *flags)
{
    if (!list || !ctx || !pts) return;
    float k = Backing(ctx);
    float w = ctx->thick * (ctx->drawing ? 2.0f : 1.0f) * k;
    uint32_t m = n < 4 ? n : 4;
    if (m >= 2) {
        BKVec2f v[4];
        BKOverlayColor c[4];
        for (uint32_t i = 0; i < m; i++) {
            v[i] = BKROIDrawMap(ctx, pts[i]);
            c[i] = ctx->color;
            if (i == 1 || i == 2) c[i].a = 0.1f;   // the faint join between the two lines (original design)
        }
        BKOverlayStroke st = Stroke(w, 1);
        BKOverlayStrokePolyline(list, v, c, m, 0, &st, ctx->color);
    }
    if (n >= 4) {
        BKVec2f q[4] = { ZoomPt(ctx, pts[0]), ZoomPt(ctx, pts[1]), ZoomPt(ctx, pts[2]), ZoomPt(ctx, pts[3]) };
        BKVec2f corner, ta, tb;
        if (BKDynamicAngleCorner(q[0], q[1], q[2], q[3], &corner, &ta, &tb)) {
            float la = hypotf(q[1].x - q[0].x, q[1].y - q[0].y), lb = hypotf(q[3].x - q[2].x, q[3].y - q[2].y);
            AngleArc(list, ctx, corner, ta, tb, la < lb ? la : lb, w, ctx->color);
            BKVec2f fromA, fromB;
            int extA = BKAngleExtensionStart(q[0], q[1], corner, &fromA), extB = BKAngleExtensionStart(q[2], q[3], corner, &fromB);
            if (extA || extB) {
                double s = Zoom(ctx);
                float dash[2] = { 4.0f * k, 4.0f * k };    // the old stipple: 2 on / 2 off, x (2 x backing)
                BKOverlayStroke st = Stroke(1.0f * k, 1);
                st.dashes = dash; st.dashCount = 2;
                BKOverlayColor dc = ctx->color;
                dc.a *= 0.7f;
                BKVec2f cv = BKROIDrawMap(ctx, (BKROIPoint){ corner.x / s, corner.y / s });
                if (extA) { BKVec2f seg[2] = { BKROIDrawMap(ctx, (BKROIPoint){ fromA.x / s, fromA.y / s }), cv }; BKOverlayStrokePolyline(list, seg, NULL, 2, 0, &st, dc); }
                if (extB) { BKVec2f seg[2] = { BKROIDrawMap(ctx, (BKROIPoint){ fromB.x / s, fromB.y / s }), cv }; BKOverlayStrokePolyline(list, seg, NULL, 2, 0, &st, dc); }
            }
        }
    }
    BKROIDrawAllHandles(list, ctx, pts, n, flags, (k + sqrtf(ctx->thick)) * 3.5f * k);
}

void BKROIDrawAxis(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   const uint8_t *flags)
{
    if (!list || !ctx || !pts) return;
    float k = Backing(ctx);
    float w = ctx->thick * (ctx->drawing ? 2.0f : 1.0f) * k;
    uint32_t m = n < 4 ? n : 4;
    if (m >= 2) BKROIDrawLine(list, ctx, pts, m, 1, w, ctx->color);
    BKROIDrawAllHandles(list, ctx, pts, n, flags, (k + sqrtf(ctx->thick)) * 3.5f * k);
    if (n < 4) return;
    double s = Zoom(ctx);
    // The two axes, in the zoomed image space (the old code's +/- 125 are in that space; float maths kept).
    BKVec2f p0 = ZoomPt(ctx, pts[0]), p1 = ZoomPt(ctx, pts[1]), p2 = ZoomPt(ctx, pts[2]), p3 = ZoomPt(ctx, pts[3]);
    BKVec2f m01 = BKV2f((p1.x + p0.x) / 2, (p1.y + p0.y) / 2), m23 = BKV2f((p3.x + p2.x) / 2, (p3.y + p2.y) / 2);
    BKVec2f m03 = BKV2f((p3.x + p0.x) / 2, (p3.y + p0.y) / 2), m21 = BKV2f((p1.x + p2.x) / 2, (p1.y + p2.y) / 2);
    float a1 = (m23.y - m01.y) / (m23.x - m01.x), b1 = m01.y - a1 * m01.x;
    float y1 = m01.y - 125, y2 = m23.y + 125, x1 = (y1 - b1) / a1, x2 = (y2 - b1) / a1;
    float a2 = (m21.y - m03.y) / (m21.x - m03.x), b2 = m03.y - a2 * m03.x;
    float x3 = m03.x - 125, x4 = m21.x + 125, y3 = a2 * x3 + b2, y4 = a2 * x4 + b2;
    const BKOverlayColor blue = { 0, 0, 1, 1 }, red = { 1, 0, 0, 1 };
    if (isfinite(x1) && isfinite(x2) && isfinite(y1) && isfinite(y2)) {
        BKROIPoint l[2] = { { x1 / s, y1 / s }, { x2 / s, y2 / s } };
        BKROIDrawLine(list, ctx, l, 2, 0, w, blue);
    }
    if (isfinite(x3) && isfinite(x4) && isfinite(y3) && isfinite(y4)) {
        BKROIPoint l[2] = { { x3 / s, y3 / s }, { x4 / s, y4 / s } };
        BKROIDrawLine(list, ctx, l, 2, 0, w, red);
    }
    BKVec2f quad[4] = { BKROIDrawMap(ctx, pts[0]), BKROIDrawMap(ctx, pts[1]), BKROIDrawMap(ctx, pts[2]), BKROIDrawMap(ctx, pts[3]) };
    BKOverlayColor fill = ctx->color;
    fill.a = 0.25f;
    BKOverlayFillPolygon(list, quad, NULL, 4, BKOverlayFillFan, 0, fill);
}

// A picture of label.width x label.height view-pixel-sized units whose corner sits at image point `at`
// moved by (dx, dy) zoomed-image units, turning with the image; flipX / flipY mirror it back.
static void ImageLabel(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIDrawLabel label, BKROIPoint at,
                       double dx, double dy, int flipX, int flipY, BKOverlayColor color, uint32_t imgW, uint32_t imgH)
{
    if (label.image < 0 || imgW == 0 || imgH == 0) return;
    double s = Zoom(ctx);
    double w = label.width / s, h = label.height / s;          // picture size in image units
    BKROIPoint q00 = { at.x + dx / s + (flipX ? w : 0), at.y + dy / s + (flipY ? h : 0) };
    double su = (flipX ? -1.0 : 1.0) * w / imgW, sv = (flipY ? -1.0 : 1.0) * h / imgH;   // image units per picture pixel
    const BKROIDrawTransform *t = &ctx->xf;
    BKVec2f u = BKV2f((float)(t->a * su), (float)(t->b * su)), v = BKV2f((float)(t->c * sv), (float)(t->d * sv));
    BKOverlayDrawImage(list, label.image, BKROIDrawMap(ctx, q00), u, v, 1, color);
}

// The list's own record of an image's size.
static int ImageSize(const BKOverlayList *list, int32_t image, uint32_t *w, uint32_t *h)
{
    uint32_t count = 0;
    const BKOverlayImage *im = BKOverlayListImages(list, &count);
    if (image < 0 || (uint32_t)image >= count) return 0;
    *w = im[image].width; *h = im[image].height;
    return 1;
}

void BKROIDrawTAGT(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                   const uint8_t *flags, const BKROIDrawLabel labels[3], int flipX, int flipY)
{
    if (!list || !ctx || !pts || n != 6) return;
    float k = Backing(ctx);
    for (int i = 0; i < 6; i += 2) BKROIDrawLine(list, ctx, pts + i, 2, 0, ctx->thick * k, ctx->color);
    uint8_t f[6];
    for (int i = 0; i < 6; i++) f[i] = (uint8_t)((flags ? flags[i] : 0) | ((i == 0 || i == 2) ? BKROIPointSkip : 0));
    BKROIDrawAllHandles(list, ctx, pts, 6, f, ctx->thick * 2.0f * k);
    if (!labels) return;
    const BKOverlayColor black = { 0, 0, 0, 1 }, yellow = { 1, 1, 0, 1 };
    for (int i = 0; i < 3; i++) {
        uint32_t iw, ih;
        if (!ImageSize(list, labels[i].image, &iw, &ih)) continue;
        BKROIPoint at = pts[2 * i + 1];
        ImageLabel(list, ctx, labels[i], at, 1, 1, flipX, flipY, black, iw, ih);
        ImageLabel(list, ctx, labels[i], at, 0, 0, flipX, flipY, yellow, iw, ih);
    }
}

void BKROIDraw2DPoint(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIPoint centre, double spacingX, double spacingY)
{
    if (!list || !ctx) return;
    float k = Backing(ctx);
    double s = Zoom(ctx);
    double yScale = (spacingX != 0 && spacingY != 0) ? spacingX / spacingY : 1.0;
    enum { N = 200 };
    BKROIPoint c[N];
    for (int i = 0; i < N; i++) {
        float angle = (float)(i * 2 * BK_DRAW_PI / N);
        c[i].x = centre.x + 8.0 * cos((double)angle) / s;
        c[i].y = centre.y + 8.0 * sin((double)angle) * yScale / s;
    }
    BKROIDrawLine(list, ctx, c, N, 1, 1.0f * k, ctx->color);
    BKOverlayColor dot = ctx->color;
    if (ctx->highlight && (ctx->selected || ctx->drawing)) { dot.r = 0.5f; dot.g = 0.5f; dot.b = 1.0f; }
    BKROIDrawDots(list, ctx, &centre, 1, (1.0f + sqrtf(ctx->thick)) * 3.5f * k, dot);
}

// An upright picture drawn label.width x label.height with its top-left at view point (x, y).
static void UprightPicture(BKOverlayList *list, BKROIDrawLabel label, float x, float y, int flipX, int flipY,
                           BKOverlayColor color)
{
    uint32_t iw, ih;
    if (!ImageSize(list, label.image, &iw, &ih)) return;
    BKVec2f u = BKV2f(label.width / iw, 0), v = BKV2f(0, label.height / ih);
    BKVec2f o = BKV2f(x, y);
    (void)flipX; (void)flipY;   // upright pictures are mirrored back by the old code: they always read normally
    int exact = fabsf(u.x - 1) < 1e-3f && fabsf(v.y - 1) < 1e-3f && fabsf(x - roundf(x)) < 1e-3f && fabsf(y - roundf(y)) < 1e-3f;
    BKOverlayDrawImage(list, label.image, o, u, v, exact ? 0 : 1, color);
}

void BKROIDrawTextROI(BKOverlayList *list, const BKROIDrawContext *ctx, BKROIDrawLabel text, BKVec2f centre,
                      float boxW, float boxH, double ratio, int flipX, int flipY)
{
    if (!list || !ctx) return;
    float k = Backing(ctx);
    if (!(ratio > 0)) ratio = 1;
    float w = text.width, h = text.height, hr = (float)(boxH / ratio);
    // The old code put the picture's corner at (centre - box / 2) in a space the view mirrors; in view pixels:
    float left = flipX ? centre.x + boxW / 2 - w : centre.x - boxW / 2;
    float top = flipY ? centre.y + hr / 2 - h : centre.y - hr / 2;
    if (text.image >= 0) {
        BKOverlayColor shadow = { 0, 0, 0, ctx->color.a };
        UprightPicture(list, text, left + (flipX ? -1.0f : 1.0f), top + (flipY ? -1.0f : 1.0f), flipX, flipY, shadow);
        UprightPicture(list, text, left, top, flipX, flipY, ctx->color);
    }
    if (ctx->highlight && (ctx->selected || ctx->drawing)) {
        const BKOverlayColor blue = { 0.5f, 0.5f, 1.0f, 1.0f };
        BKVec2f c4[4] = { BKV2f(centre.x - boxW / 2, centre.y - hr / 2), BKV2f(centre.x - boxW / 2, centre.y + hr / 2),
                          BKV2f(centre.x + boxW / 2, centre.y + hr / 2), BKV2f(centre.x + boxW / 2, centre.y - hr / 2) };
        BKOverlayPoints(list, c4, NULL, 4, 6.0f * k, 1, 1, blue);
    }
}

int BKROIMaskOutline(const uint8_t *mask, uint32_t w, uint32_t h, uint8_t *dst)
{
    if (!mask || !dst || w == 0 || h == 0) return 0;
    uint32_t W = w + 2, H = h + 2;
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x++) {
            // (x, y) in the padded mask is (x - 1, y - 1) in the brush mask.
            int inside = x >= 1 && y >= 1 && x <= w && y <= h && mask[(size_t)(y - 1) * w + (x - 1)];
            uint8_t best = 0;
            if (!inside)
                for (int dy = -1; dy <= 1 && !best; dy++)
                    for (int dx = -1; dx <= 1; dx++) {
                        long mx = (long)x - 1 + dx, my = (long)y - 1 + dy;
                        if (mx < 0 || my < 0 || mx >= (long)w || my >= (long)h) continue;
                        if (mask[(size_t)my * w + (size_t)mx]) { best = 255; break; }
                    }
            dst[(size_t)y * W + x] = best;
        }
    return 1;
}

void BKROIDrawBrush(BKOverlayList *list, const BKROIDrawContext *ctx, const uint8_t *mask, uint32_t w, uint32_t h,
                    double upLeftX, double upLeftY, int linear, const uint8_t *outline, float handleSize)
{
    if (!list || !ctx || !mask || w == 0 || h == 0) return;
    const BKROIDrawTransform *t = &ctx->xf;
    BKVec2f u = BKV2f((float)t->a, (float)t->b), v = BKV2f((float)t->c, (float)t->d);   // one image pixel
    if (outline) {
        int32_t oi = BKOverlayAddImage(list, w + 2, h + 2, BKOverlayImageAlpha8, outline, w + 2);
        const BKOverlayColor black = { 0, 0, 0, 1 };
        if (oi >= 0) BKOverlayDrawImage(list, oi, BKROIDrawMap(ctx, (BKROIPoint){ upLeftX - 1, upLeftY - 1 }), u, v, linear, black);
    }
    int32_t mi = BKOverlayAddImage(list, w, h, BKOverlayImageAlpha8, mask, w);
    if (mi >= 0) BKOverlayDrawImage(list, mi, BKROIDrawMap(ctx, (BKROIPoint){ upLeftX, upLeftY }), u, v, linear, ctx->color);
    if (!outline && ctx->highlight && (ctx->selected || ctx->drawing)) {
        const BKOverlayColor blue = { 0.5f, 0.5f, 1.0f, 1.0f };
        BKROIPoint c4[4] = { { upLeftX, upLeftY }, { upLeftX + w, upLeftY }, { upLeftX, upLeftY + h }, { upLeftX + w, upLeftY + h } };
        BKROIDrawDots(list, ctx, c4, 4, handleSize, blue);
    }
}

void BKROIDrawLayer(BKOverlayList *list, const BKROIDrawContext *ctx, int32_t image, uint32_t imgW, uint32_t imgH,
                    BKROIPoint p1, BKROIPoint p2, BKROIPoint p3, BKROIPoint p4, int handles)
{
    if (!list || !ctx) return;
    if (image >= 0 && imgW > 0 && imgH > 0) {
        BKVec2f o = BKROIDrawMap(ctx, p1), a = BKROIDrawMap(ctx, p2), b = BKROIDrawMap(ctx, p4);
        BKVec2f u = BKV2f((a.x - o.x) / imgW, (a.y - o.y) / imgW), v = BKV2f((b.x - o.x) / imgH, (b.y - o.y) / imgH);
        const BKOverlayColor white = { 1, 1, 1, 1 };
        BKOverlayDrawImage(list, image, o, u, v, 1, white);
    }
    if (handles) {
        const BKOverlayColor blue = { 0.5f, 0.5f, 1.0f, 1.0f };
        BKROIPoint c4[4] = { p1, p2, p3, p4 };
        BKROIDrawDots(list, ctx, c4, 4, 8.0f * Backing(ctx), blue);
    }
}

void BKROIDrawTextBoxItems(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIDrawTextBox *box)
{
    if (!list || !ctx || !box) return;
    float k = Backing(ctx);
#define BOXV(x, y) BKV2f((x) * box->scale + box->offsetX, (y) * box->scale + box->offsetY)
    if (box->connector) {
        // Quadratic curve: start = the box's left middle, control = 30 left of the anchor, end = the anchor.
        float sx = box->boxX, sy = box->boxY + box->boxH / 2, cx = box->anchorX - 30, cy = box->anchorY;
        BKVec2f c[31];
        for (int i = 0; i <= 30; i++) {
            float t = (float)i / 30.0f, m = 1 - t;
            c[i] = BOXV(m * m * sx + 2 * m * t * cx + t * t * box->anchorX, m * m * sy + 2 * m * t * cy + t * t * box->anchorY);
        }
        BKOverlayColor under = box->asleep ? (BKOverlayColor){ 0, 0, 0, 1 } : (BKOverlayColor){ 0.3f, 0, 0, 1 };
        const BKOverlayColor white = { 1, 1, 1, 1 };
        BKOverlayStroke st = Stroke(3.0f * k * box->scale, 0);
        BKOverlayStrokePolyline(list, c, NULL, 31, 0, &st, under);
        st = Stroke(1.0f * k * box->scale, 0);
        BKOverlayStrokePolyline(list, c, NULL, 31, 0, &st, white);
    }
    BKOverlayColor tc = ctx->color;
    tc.a = 1;
    const BKOverlayColor black = { 0, 0, 0, 1 };
    int line = 0;
    for (int i = 0; i < 6; i++) {
        BKROIDrawLabel L = box->lines[i];
        if (L.image < 0) continue;
        long xc = (long)(box->textX - 2 * k), yc = (long)(box->textY + line * box->lineHeight - L.height);
        BKVec2f o = BOXV((float)xc, (float)yc), o1 = BOXV((float)xc + 1, (float)yc + 1);
        BKROIDrawLabel S = L;
        S.width *= box->scale; S.height *= box->scale;
        UprightPicture(list, S, o1.x, o1.y, 0, 0, black);
        UprightPicture(list, S, o.x, o.y, 0, 0, tc);
        line++;
    }
#undef BOXV
}

// ---- Selection box (2026-11-17) -------------------------------------------------------------------------

void BKROIDrawSelectionBox(BKOverlayList *list, const BKROIDrawContext *ctx, const BKROIPoint *pts, uint32_t n,
                           float pad)
{
    if (!list || !ctx || !pts || n == 0) return;
    float b = ctx->backing > 0 ? ctx->backing : 1;
    BKVec2f p = BKROIDrawMap(ctx, pts[0]);
    float x0 = p.x, y0 = p.y, x1 = p.x, y1 = p.y;
    for (uint32_t i = 1; i < n; i++) {
        p = BKROIDrawMap(ctx, pts[i]);
        if (p.x < x0) x0 = p.x;
        if (p.x > x1) x1 = p.x;
        if (p.y < y0) y0 = p.y;
        if (p.y > y1) y1 = p.y;
    }
    // Whole-pixel corners plus half a pixel: a 1-pixel line then covers exactly one pixel row / column.
    float d = pad * b;
    x0 = floorf(x0 - d) + 0.5f; y0 = floorf(y0 - d) + 0.5f;
    x1 = ceilf(x1 + d) - 0.5f;  y1 = ceilf(y1 + d) - 0.5f;
    BKVec2f box[4] = { BKV2f(x0, y0), BKV2f(x1, y0), BKV2f(x1, y1), BKV2f(x0, y1) };
    BKOverlayStroke st;
    memset(&st, 0, sizeof st);
    st.width = 1.0f * b;
    st.cap = BKOverlayCapButt; st.join = BKOverlayJoinMiter; st.miterLimit = 10;
    st.smooth = 0;
    BKOverlayStrokePolyline(list, box, NULL, 4, 1, &st, (BKOverlayColor){ 0, 0, 0, 0.55f });   // dark under-line
    float dash[2] = { 4.0f * b, 4.0f * b };
    st.dashes = dash; st.dashCount = 2;
    BKOverlayStrokePolyline(list, box, NULL, 4, 1, &st, (BKOverlayColor){ 1, 1, 1, 0.95f });  // white dashes
}
