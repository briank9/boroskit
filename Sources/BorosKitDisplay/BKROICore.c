// BorosKitDisplay: BKROICore - see BKROICore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code. The numbers it gives
// were checked against values RECORDED from the old Horos code (References/roi-reference-2026-11-16.json);
// where a float/double detail matters, the comment names the rule that matches the recording.

#include "BKROICore.h"
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define BK_ROI_PI 3.14159265358979323846   /* own constant: M_PI is not part of strict C99 */
#define BK_ROI_OVAL_POINTS 200             /* points round an oval outline */

void BKROIPointListFree(BKROIPointList *list)
{
    if (!list) return;
    free(list->points);
    list->points = NULL;
    list->count = 0;
}

void BKROIRunListFree(BKROIRunList *list)
{
    if (!list) return;
    free(list->runs);
    list->runs = NULL;
    list->count = 0;
}

static BKROIPointList NewPointList(uint32_t n)
{
    BKROIPointList l = { NULL, 0 };
    if (n == 0) return l;
    l.points = (BKROIPoint *)malloc(sizeof(BKROIPoint) * n);
    if (l.points) l.count = n;
    return l;
}

// ---------------------------------------------------------------------------------------------------
// Outline

BKROIPointList BKROIOutline(const BKROIShape *roi)
{
    BKROIPointList l = { NULL, 0 };
    if (!roi) return l;
    if (roi->kind == BKROIKindRect) {
        // Corners in the recorded order: (minX, minY), (minX, maxY), (maxX, maxY), (maxX, minY).
        double x0 = roi->rectW >= 0 ? roi->rectX : roi->rectX + roi->rectW, x1 = x0 + fabs(roi->rectW);
        double y0 = roi->rectH >= 0 ? roi->rectY : roi->rectY + roi->rectH, y1 = y0 + fabs(roi->rectH);
        l = NewPointList(4);
        if (l.points) {
            l.points[0].x = x0; l.points[0].y = y0;
            l.points[1].x = x0; l.points[1].y = y1;
            l.points[2].x = x1; l.points[2].y = y1;
            l.points[3].x = x1; l.points[3].y = y0;
        }
        return l;
    }
    if (roi->kind == BKROIKindOval) {
        l = NewPointList(BK_ROI_OVAL_POINTS);
        for (uint32_t i = 0; l.points && i < BK_ROI_OVAL_POINTS; i++) {
            // The step angle is held as a float before cos/sin (this matches the recorded points).
            float angle = (float)((double)(i * 2) * BK_ROI_PI / BK_ROI_OVAL_POINTS);
            // 2026-11-25 (D3, -ffp-contract=off everywhere): "x + w * cos" is written as ONE fused
            // multiply-add, fma(w, cos, x), on purpose. The recorded Horos build let the compiler fuse
            // exactly this step; spelling it out keeps the recorded points bit for bit, and fma() is
            // correctly rounded by every C99 library, so the result is the same on every platform.
            l.points[i].x = fma(roi->rectW, cos((double)angle), roi->rectX);
            l.points[i].y = fma(roi->rectH, sin((double)angle), roi->rectY);
        }
        return l;
    }
    if (roi->kind == BKROIKindPoint) {
        l = NewPointList(1);
        if (l.points) { l.points[0].x = roi->rectX; l.points[0].y = roi->rectY; }
        return l;
    }
    l = NewPointList(roi->count);
    if (l.points && roi->points) memcpy(l.points, roi->points, sizeof(BKROIPoint) * roi->count);
    return l;
}

// ---------------------------------------------------------------------------------------------------
// Smoothed curve
//
// Unknowns: q[k] = half the second derivative ("bend") at padded point k, for k = 1..m; q[0] = q[m+1] = 0
// (straight ends one point beyond the real ends). With t[k] the running distance along the points and
// h[k] = distance from point k to k+1 (both times scale), each inner point gives one equation
//     lo[k] q[k-1] + 4 q[k] + up[k] q[k+1] = r[k]
// (lo = 2 h[k-1] / (h[k-1] + h[k]), up = 2 h[k] / (h[k-1] + h[k]), r = 6 (change of slope) / (h[k-1] + h[k])),
// i.e. the slope and bend are the same on both sides of every point. The tridiagonal system is solved
// with the usual forward sweep and back substitution. A piece from point k to k+1 is then
//     P(s) = P[k] + b s + q[k] s^2 + e s^3,  s = 0 .. h[k],
// b = (P[k+1] - P[k]) / h[k] - h[k] (q[k+1] + 2 q[k]) / 3, e = (q[k+1] - q[k]) / (3 h[k]).
// (Slopes use differences of t, h is measured directly, and P(s) is evaluated term by term - these are
// the choices that reproduce the recorded curve points.)

static void SolveBends(const double *v, const double *t, const double *h, uint32_t nb, double *q, double *gam)
{
    // v: padded coordinate (x or y), nb values; q: result (q[0] = q[nb-1] = 0); gam: nb values of work.
    // Rows k = 1 .. nb-2; row 1 has no left term and row nb-2 no right term (straight ends).
    for (uint32_t k = 0; k < nb; k++) { q[k] = 0; gam[k] = 0; }
    double pivot = 4.0;
    for (uint32_t k = 1; k + 1 < nb; k++) {
        double r = 6.0 * (((v[k - 1] - v[k]) / (t[k - 1] - t[k])) - ((v[k] - v[k + 1]) / (t[k] - t[k + 1])))
                   / (t[k - 1] - t[k + 1]);
        if (k == 1) { q[1] = r / pivot; continue; }
        double lo = 2.0 * h[k - 1] / (h[k] + h[k - 1]);                 // this row's left term
        double upPrev = 2.0 * h[k - 1] / (h[k - 1] + h[k - 2]);         // the previous row's right term
        gam[k] = upPrev / pivot;
        pivot = 4.0 - lo * gam[k];
        q[k] = (r - lo * q[k - 1]) / pivot;
    }
    for (uint32_t k = nb - 2; k >= 1; k--)                              // back substitution
        q[k] -= gam[k + 1] * q[k + 1];
}

static BKROIPointList CurveImpl(const BKROIShape *roi, double scale, int32_t **pieces)
{
    if (pieces) *pieces = NULL;
    BKROIPointList outline = BKROIOutline(roi);
    if (!roi || !roi->smooth || outline.count < 3 ||
        !(roi->kind == BKROIKindOpenPolygon || roi->kind == BKROIKindClosedPolygon || roi->kind == BKROIKindPencil))
        return outline;
    if (scale > 5) scale = 5;

    // Input sequence: the points, plus the first again for a closed kind (unless being drawn).
    int closed = (roi->kind != BKROIKindOpenPolygon) && !roi->drawing;
    uint32_t tot = outline.count + (closed ? 1 : 0);
    uint32_t nb = tot + 2;   // padded: one wrap-round point before and after
    double *buf = (double *)calloc((size_t)nb * 9, sizeof(double));
    if (!buf) return outline;
    double *px = buf, *py = buf + nb, *t = buf + 2 * nb, *h = buf + 3 * nb, *qx = buf + 4 * nb,
           *qy = buf + 5 * nb, *work = buf + 6 * nb;   // (buf + 7 nb .. 9 nb: spare)
    for (uint32_t i = 0; i < tot; i++) {
        BKROIPoint p = outline.points[i < outline.count ? i : 0];
        px[i + 1] = p.x; py[i + 1] = p.y;
    }
    // Padding (recorded rule): before = the input's second-to-last point, after = its second point.
    px[0] = px[nb - 3]; py[0] = py[nb - 3];
    px[nb - 1] = px[2]; py[nb - 1] = py[2];

    // Two equal neighbours (e.g. points closer than the drawing resolution): no smoothing.
    for (uint32_t i = 1; i < nb; i++)
        if (px[i] == px[i - 1] && py[i] == py[i - 1]) { free(buf); return outline; }

    t[0] = 0;
    for (uint32_t i = 0; i + 1 < nb; i++) {
        double dx = px[i + 1] - px[i], dy = py[i + 1] - py[i];
        h[i] = sqrt(dx * dx + dy * dy) * scale;
        t[i + 1] = t[i] + h[i];
    }
    SolveBends(px, t, h, nb, qx, work);
    SolveBends(py, t, h, nb, qy, work);

    // Count, then sample: each piece k = 1 .. nb-3 gives its start + one point per whole step.
    uint32_t total = 0;
    for (uint32_t k = 1; k + 2 < nb; k++) total += 1 + (uint32_t)(h[k] >= 1 ? floor(h[k]) : 0);
    BKROIPointList curve = NewPointList(total);
    if (!curve.points) { free(buf); return outline; }
    int32_t *piece = pieces ? (int32_t *)malloc(sizeof(int32_t) * (total ? total : 1)) : NULL;
    uint32_t o = 0;
    for (uint32_t k = 1; k + 2 < nb; k++) {
        double bx = ((px[k + 1] - px[k]) / h[k]) - (h[k] / 3.0) * (qx[k + 1] + 2.0 * qx[k]);
        double by = ((py[k + 1] - py[k]) / h[k]) - (h[k] / 3.0) * (qy[k + 1] + 2.0 * qy[k]);
        double ex = (qx[k + 1] - qx[k]) / (3.0 * h[k]), ey = (qy[k + 1] - qy[k]) / (3.0 * h[k]);
        if (piece) piece[o] = (int32_t)k - 1;   // piece k of the padded list = the user's piece k - 1
        curve.points[o].x = px[k]; curve.points[o].y = py[k]; o++;
        for (long s = 1; s <= h[k]; s++) {
            curve.points[o].x = px[k] + bx * (double)s + qx[k] * (double)(s * s) + ex * (double)(s * s * s);
            curve.points[o].y = py[k] + by * (double)s + qy[k] * (double)(s * s) + ey * (double)(s * s * s);
            if (piece) piece[o] = (int32_t)k - 1;
            o++;
        }
    }
    curve.count = o;
    free(buf);
    BKROIPointListFree(&outline);
    if (pieces) *pieces = piece;
    return curve;
}

BKROIPointList BKROICurve(const BKROIShape *roi, double scale)
{
    return CurveImpl(roi, scale, NULL);
}

BKROIPointList BKROICurveWithPieces(const BKROIShape *roi, double scale, int32_t **pieces)
{
    return CurveImpl(roi, scale, pieces);
}

// ---------------------------------------------------------------------------------------------------
// Measurements

float BKROIPolygonAreaPixels(const BKROIPoint *pts, uint32_t n)
{
    // Shoelace sum on the coordinates held as floats, summed in float (as recorded).
    float area = 0;
    for (uint32_t i = 0; pts && i < n; i++) {
        uint32_t j = (i + 1) % n;
        float xi = (float)pts[i].x, yi = (float)pts[i].y, xj = (float)pts[j].x, yj = (float)pts[j].y;
        // 2026-11-25 (D3): each step is one explicit fused multiply-add (what the recorded Horos build's
        // compiler did implicitly); fmaf is correctly rounded everywhere, so this is platform-independent.
        area = fmaf(xi, yj, area);
        area = fmaf(-yi, xj, area);
    }
    area *= 0.5f;
    return fabsf(area);
}

float BKROIAreaCm2(const BKROIShape *roi, const BKROIPointList *curve)
{
    if (!roi || (roi->spacingX == 0 && roi->spacingY == 0)) return 0;
    switch (roi->kind) {
        case BKROIKindDynamicAngle:
        case BKROIKindAxis:
        case BKROIKindOpenPolygon:
        case BKROIKindClosedPolygon:
        case BKROIKindPencil: {
            float px = curve ? BKROIPolygonAreaPixels(curve->points, curve->count) : 0;
            return (float)((double)px * roi->spacingX * roi->spacingY / 100.);   // pixels -> mm2 -> cm2
        }
        case BKROIKindRect:
            return (float)(roi->rectW * roi->spacingX * roi->rectH * roi->spacingY / 100.);
        case BKROIKindOval: {
            float px = (float)(fabs(BK_ROI_PI * roi->rectW * 2. * roi->rectH * 2.) / 4.);   // pi a b, held as float
            return (float)((double)px * roi->spacingX * roi->spacingY / 100.);
        }
        default:
            return 0;
    }
}

float BKROILength(BKROIPoint a, BKROIPoint b, double spacingX, double spacingY, int inPixels)
{
    double sx = fabs(a.x - b.x), sy = fabs(a.y - b.y);
    int mm = (spacingX != 0 && spacingY != 0) && !inPixels;
    if (mm) { sx *= spacingX; sy *= spacingY; }
    float len;
    if (sx == 0) len = (float)sy;
    else if (sy == 0) len = (float)sx;
    else len = (float)(sy / sin(atan(sy / sx)));   // same as the hypotenuse; this form matches the recording
    if (mm) len = (float)(len / 10.0);              // mm -> cm
    return len;
}

float BKROIAngle(BKROIPoint a, BKROIPoint vertex, BKROIPoint b, double spacingX, double spacingY)
{
    double sx = 1, sy = 1;
    if (spacingX != 0 && spacingY != 0) { sx = spacingX; sy = spacingY; }
    float ax = (float)(a.x * sx - vertex.x * sx), ay = (float)(a.y * sy - vertex.y * sy);
    float bx = (float)(b.x * sx - vertex.x * sx), by = (float)(b.y * sy - vertex.y * sy);
    if (ax == 0 && ay == 0) return 0;
    float c = (float)((ax * bx + ay * by) / (sqrt(ax * ax + ay * ay) * sqrt(bx * bx + by * by)));
    const float degree = (float)(BK_ROI_PI / 180.0f);   // one degree in radians, held as a float (recorded)
    return (float)(acos(c) / degree);
}

BKROIPoint BKROICentroid(const BKROIShape *roi)
{
    BKROIPoint c = { 0, 0 };
    if (!roi) return c;
    if (roi->kind == BKROIKindRect || roi->kind == BKROIKindOval || roi->kind == BKROIKindPoint) {
        c.x = roi->rectX; c.y = roi->rectY;
        return c;
    }
    float n = (float)roi->count;
    for (uint32_t i = 0; roi->points && i < roi->count; i++) {
        c.x += (float)roi->points[i].x / n;   // each share in float, summed in double (recorded)
        c.y += (float)roi->points[i].y / n;
    }
    return c;
}

// ---------------------------------------------------------------------------------------------------
// Inside pixels

typedef struct { long x, y; } WholePt;

// One side of the image cut (Sutherland-Hodgman): keep the part of the closed outline `in` on the inside
// of the line `side` (0 left x >= lim, 1 right x <= lim, 2 top y >= lim, 3 bottom y <= lim).
static long CutSide(const WholePt *in, long n, WholePt *out, int side, long lim)
{
    long o = 0;
    for (long v = 0; v < n; v++) {
        WholePt a = in[v], b = in[(v + 1) % n];
        int vertical = side >= 2;
        long ca = vertical ? a.y : a.x, cb = vertical ? b.y : b.x;
        int aIn = (side == 0 || side == 2) ? ca >= lim : ca <= lim;
        int bIn = (side == 0 || side == 2) ? cb >= lim : cb <= lim;
        if (aIn && bIn) { out[o++] = b; continue; }
        if (aIn == bIn) continue;   // both outside
        // Crossing point, computed in float and cut to whole pixels (recorded).
        float dx = (float)(b.x - a.x), dy = (float)(b.y - a.y), m = 1;
        if (dx != 0) m = dy / dx;
        WholePt c;
        if (!vertical) {
            c.x = lim;
            c.y = (long)((float)a.y + m * (float)(lim - a.x));
        } else {
            c.y = lim;
            c.x = (dx != 0) ? (long)((float)a.x + (float)(lim - a.y) / m) : a.x;
        }
        out[o++] = c;
        if (bIn) out[o++] = b;   // entering: the crossing, then the inside end
    }
    return o;
}

typedef struct {
    long top, bottom;      // rows covered (inclusive)
    long xTop, rowTop;     // the edge's top point (rowTop: its row before any skip)
    long dx, dy, dir;      // |x change|, y change (> 0), x direction
} Edge;

static int CmpLong(const void *a, const void *b)
{
    long x = *(const long *)a, y = *(const long *)b;
    return (x > y) - (x < y);
}

static int AddRun(BKROIRunList *l, uint32_t *cap, long y, long x0, long x1)
{
    if (l->count == *cap) {
        uint32_t nc = *cap ? *cap * 2 : 64;
        BKROIRun *r = (BKROIRun *)realloc(l->runs, sizeof(BKROIRun) * nc);
        if (!r) return 0;
        l->runs = r; *cap = nc;
    }
    l->runs[l->count].y = (int32_t)y; l->runs[l->count].x0 = (int32_t)x0; l->runs[l->count].x1 = (int32_t)x1;
    l->count++;
    return 1;
}

BKROIRunList BKROIInsideRuns(const BKROIPoint *curve, uint32_t n, int32_t width, int32_t height)
{
    BKROIRunList runs = { NULL, 0 };
    if (!curve || n < 3 || width <= 0 || height <= 0) return runs;
    // Whole pixels (cut towards zero), then the image cut when needed.
    // Each image side can add at most one point per outline edge: 2^4 x n bounds the cut outline.
    size_t room = (size_t)n * 16 + 16;
    WholePt *a = (WholePt *)malloc(sizeof(WholePt) * room * 2), *b = a ? a + room : NULL;
    if (!a) return runs;
    long no = n;
    int cut = 0;
    for (uint32_t i = 0; i < n; i++) {
        a[i].x = (long)curve[i].x; a[i].y = (long)curve[i].y;
        if (a[i].x < 0 || a[i].y < 0 || a[i].x >= width || a[i].y >= height) cut = 1;
    }
    if (cut) {
        no = CutSide(a, no, b, 0, 0);
        no = CutSide(b, no, a, 1, width - 1);
        no = CutSide(a, no, b, 2, 0);
        no = CutSide(b, no, a, 3, height - 1);
    }
    if (no <= 2) { free(a); return runs; }

    // Edges (flat ones skipped). A corner where the outline keeps going down (or up) is counted once:
    // the edge arriving there gives up that row.
    Edge *e = (Edge *)malloc(sizeof(Edge) * (size_t)no);
    long *xs = (long *)malloc(sizeof(long) * ((size_t)no + 1));
    if (!e || !xs) { free(a); free(e); free(xs); return runs; }
    long ne = 0, firstRow = LONG_MAX;
    for (long i = 0; i < no; i++) {
        WholePt p1 = a[i], p2 = a[(i + 1) % no];
        if (p1.y == p2.y) continue;
        WholePt p3 = p2;
        for (long j = (i + 2) % no; ; j = (j + 1) % no) { p3 = a[j]; if (p3.y != p2.y) break; }
        Edge E;
        E.dx = labs(p1.x - p2.x);
        if (p2.y > p1.y) {   // going down: top p1
            E.top = E.rowTop = p1.y; E.bottom = p2.y; E.xTop = p1.x; E.dir = (p2.x > p1.x) - (p2.x < p1.x);
            if (p3.y > p2.y) E.bottom--;
        } else {             // going up: top p2
            E.top = E.rowTop = p2.y; E.bottom = p1.y; E.xTop = p2.x; E.dir = (p1.x > p2.x) - (p1.x < p2.x);
            if (p3.y < p2.y) E.top++;
        }
        E.dy = labs(p2.y - p1.y);
        if (E.top < firstRow) firstRow = E.top;
        e[ne++] = E;
    }
    uint32_t cap = 0;
    for (long y = firstRow; ne > 0; y++) {
        long nx = 0;
        for (long k = 0; k < ne; k++) {
            if (y < e[k].top || y > e[k].bottom) continue;
            long steps = y - e[k].rowTop;
            xs[nx++] = e[k].xTop + e[k].dir * (((e[k].dy >> 1) + steps * e[k].dx) / e[k].dy);
        }
        if (nx == 0) break;   // the first row no edge reaches ends the scan
        qsort(xs, (size_t)nx, sizeof(long), CmpLong);
        if (nx % 2) { xs[nx] = xs[nx - 1]; nx++; }
        for (long k = 0; k < nx; k += 2) {
            long x0 = xs[k], x1 = xs[k + 1];
            if (x0 < 0) x0 = 0;
            if (x1 < 0) x1 = 0;
            if (x0 > width - 1) x0 = width - 1;
            if (x1 > width - 1) x1 = width - 1;
            if (y < 0 || y >= height) continue;
            if (!AddRun(&runs, &cap, y, x0, x1)) goto done;   // out of memory: what was found so far
        }
    }
done:
    free(a); free(e); free(xs);
    return runs;
}

BKROIStats BKROIStatsOfRuns(const BKROIRunList *runs, const float *image, int32_t width, int32_t height)
{
    BKROIStats s;
    memset(&s, 0, sizeof s);
    double total = 0, mn = FLT_MAX, mx = -FLT_MAX, mean = 0, dev = 0;
    uint32_t count = 0;
    for (uint32_t r = 0; runs && image && r < runs->count; r++) {
        const BKROIRun *u = &runs->runs[r];
        if (u->y < 0 || u->y >= height) continue;
        for (int32_t x = u->x0; x <= u->x1; x++) {
            float v = image[(size_t)u->y * (size_t)width + (size_t)x];
            total += v;
            if (mn > v) mn = v;
            if (mx < v) mx = v;
            count++;
        }
    }
    if (count) mean = total / count;
    for (uint32_t r = 0; runs && image && r < runs->count; r++) {
        const BKROIRun *u = &runs->runs[r];
        if (u->y < 0 || u->y >= height) continue;
        for (int32_t x = u->x0; x <= u->x1; x++) {
            float d = (float)(mean - image[(size_t)u->y * (size_t)width + (size_t)x]);   // in float (recorded)
            d *= d;
            dev += d;
        }
    }
    float fdev = (float)dev;
    fdev = fdev / (float)((long)count - 1);
    s.dev = (float)sqrt(fdev);
    s.count = count;
    s.total = (float)total;
    s.mean = (float)mean;
    s.min = (mn == FLT_MAX) ? 0 : (float)mn;
    s.max = (mx == -FLT_MAX) ? 0 : (float)mx;
    return s;
}

float BKROIPointValue(BKROIPoint p, const float *image, int32_t width, int32_t height, int32_t *x, int32_t *y)
{
    long ix = (long)p.x, iy = (long)p.y;
    if (x) *x = (int32_t)ix;
    if (y) *y = (int32_t)iy;
    if (!image || ix < 0 || iy < 0 || ix >= width || iy >= height) return 0;
    return image[(size_t)iy * (size_t)width + (size_t)ix];
}

int BKROIContainsPoint(int32_t kind, const BKROIPoint *curve, uint32_t n, double x, double y)
{
    if (!curve || n == 0) return 0;
    long minx = (long)(float)curve[0].x, maxx = minx, miny = (long)(float)curve[0].y, maxy = miny;
    for (uint32_t i = 0; i < n; i++) {
        long cx = (long)(float)curve[i].x, cy = (long)(float)curve[i].y;   // held as float, cut (recorded)
        if (minx > cx) minx = cx;
        if (maxx < cx) maxx = cx;
        if (miny > cy) miny = cy;
        if (maxy < cy) maxy = cy;
    }
    if (x < minx || x > maxx || y < miny || y > maxy) return 0;
    if (kind == BKROIKindRect) return 1;
    double px = (double)(float)(long)x, py = (double)(float)(long)y;
    int inside = 0;
    for (uint32_t i = 0, j = n - 1; i < n; j = i++) {
        const BKROIPoint *pi = &curve[i], *pj = &curve[j];
        int spans = (pi->y <= py && py < pj->y) || (pj->y <= py && py < pi->y);
        if (spans && px < (pj->x - pi->x) * (py - pi->y) / (pj->y - pi->y) + pi->x) inside = !inside;
    }
    return inside;
}

// ---------------------------------------------------------------------------------------------------
// Brush ROIs, colour images, higher moments (plan step 7 remainder, 2026-11-16)

BKROIRunList BKROIMaskRuns(const uint8_t *mask, int32_t maskW, int32_t maskH, int32_t left, int32_t top,
                           int32_t width, int32_t height)
{
    BKROIRunList l = { NULL, 0 };
    if (!mask || maskW <= 0 || maskH <= 0 || width <= 0 || height <= 0) return l;
    uint32_t cap = 0;
    for (int32_t y = 0; y < maskH; y++) {
        int32_t iy = y + top;
        if (iy < 0 || iy >= height) continue;
        const uint8_t *row = mask + (size_t)y * (size_t)maskW;
        int32_t x = 0;
        while (x < maskW) {
            while (x < maskW && (row[x] == 0 || x + left < 0 || x + left >= width)) x++;
            if (x >= maskW) break;
            int32_t x0 = x;
            while (x < maskW && row[x] != 0 && x + left < width) x++;
            if (l.count == cap) {
                uint32_t nc = cap ? cap * 2 : 64;
                BKROIRun *nr = (BKROIRun *)realloc(l.runs, sizeof(BKROIRun) * nc);
                if (!nr) { BKROIRunListFree(&l); return l; }
                l.runs = nr; cap = nc;
            }
            l.runs[l.count].y = iy; l.runs[l.count].x0 = x0 + left; l.runs[l.count].x1 = x - 1 + left;
            l.count++;
        }
    }
    return l;
}

uint32_t BKROIMaskCount(const uint8_t *mask, int32_t maskW, int32_t maskH)
{
    uint32_t n = 0;
    if (!mask || maskW <= 0 || maskH <= 0) return 0;
    for (size_t i = 0; i < (size_t)maskW * (size_t)maskH; i++) if (mask[i]) n++;
    return n;
}

int BKROIMaskContains(const uint8_t *mask, int32_t maskW, int32_t maskH, int32_t left, int32_t top,
                      double x, double y)
{
    if (!mask || !(x == x) || !(y == y)) return 0;
    double mx = floor(x) - left, my = floor(y) - top;
    if (mx < 0 || my < 0 || mx >= maskW || my >= maskH) return 0;
    return mask[(size_t)my * (size_t)maskW + (size_t)mx] != 0;
}

float BKROIColorValue(const uint8_t *argb)
{
    return (float)((argb[1] + argb[2] + argb[3]) / 3.0);
}

uint32_t BKROIRunsPixelCount(const BKROIRunList *runs, int32_t width, int32_t height)
{
    uint32_t n = 0;
    (void)width;
    for (uint32_t r = 0; runs && r < runs->count; r++) {
        const BKROIRun *u = &runs->runs[r];
        if (u->y < 0 || u->y >= height || u->x1 < u->x0) continue;
        n += (uint32_t)(u->x1 - u->x0 + 1);
    }
    return n;
}

uint32_t BKROIValuesOfRuns(const BKROIRunList *runs, const float *image, const uint8_t *argb,
                           int32_t width, int32_t height, float *values, float *locations)
{
    uint32_t n = 0;
    if (!values || (!image && !argb)) return 0;
    for (uint32_t r = 0; runs && r < runs->count; r++) {
        const BKROIRun *u = &runs->runs[r];
        if (u->y < 0 || u->y >= height) continue;
        for (int32_t x = u->x0; x <= u->x1; x++) {
            size_t i = (size_t)u->y * (size_t)width + (size_t)x;
            values[n] = image ? image[i] : BKROIColorValue(argb + 4 * i);
            if (locations) { locations[2 * n] = (float)x; locations[2 * n + 1] = (float)u->y; }
            n++;
        }
    }
    return n;
}

BKROIStats BKROIStatsOfValues(const float *values, uint32_t count)
{
    BKROIStats s;
    memset(&s, 0, sizeof s);
    double total = 0, mn = FLT_MAX, mx = -FLT_MAX, mean = 0, dev = 0;
    if (!values) count = 0;
    for (uint32_t i = 0; i < count; i++) {
        float v = values[i];
        total += v;
        if (mn > v) mn = v;
        if (mx < v) mx = v;
    }
    if (count) mean = total / count;
    for (uint32_t i = 0; i < count; i++) {
        float d = (float)(mean - values[i]);   // in float (recorded)
        d *= d;
        dev += d;
    }
    float fdev = (float)dev;
    fdev = fdev / (float)((long)count - 1);
    s.dev = (float)sqrt(fdev);
    s.count = count;
    s.total = (float)total;
    s.mean = (float)mean;
    s.min = (mn == FLT_MAX) ? 0 : (float)mn;
    s.max = (mx == -FLT_MAX) ? 0 : (float)mx;
    return s;
}

// Central moment of order k, divided by count - 1 (as recorded).
static double CentralMoment(const float *v, uint32_t n, double mean, int k)
{
    double sum = 0;
    for (uint32_t i = 0; i < n; i++) sum += pow(v[i] - mean, k);
    return sum / ((double)n - 1);
}

void BKROIMoments(const float *values, uint32_t count, double mean, double *skewness, double *kurtosis)
{
    if (skewness) *skewness = 0;
    if (kurtosis) *kurtosis = 0;
    if (!values || count < 2) return;
    double sd = sqrt(CentralMoment(values, count, mean, 2));
    if (skewness) *skewness = CentralMoment(values, count, mean, 3) / (sd * sd * sd);
    if (kurtosis) *kurtosis = CentralMoment(values, count, mean, 4) / (sd * sd * sd * sd) - 3.0;
}
