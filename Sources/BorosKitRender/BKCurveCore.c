// BorosKitRender: the curve of the curved MPR (plain C). See include/BKCurveCore.h for what each
// function does, the rules and the porting notes (VULKAN: safe to translate directly - CPU-side C99).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKCurveCore.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define BK_CURVE_MAX_DEPTH 16   // at most 2^16 halvings per piece when flattening

static int BKCFinite(BKVec3d v) { return isfinite(v.x) && isfinite(v.y) && isfinite(v.z); }

// What: unit vector, or (0,0,0) for a zero vector (no NaNs).
static BKVec3d BKCUnit(BKVec3d v)
{
    double l = BKV3dLength(v);
    return l > 0 ? BKV3dDiv(v, l) : BKV3d(0, 0, 0);
}

// What: v minus its part along unit u.
static BKVec3d BKCPerp(BKVec3d v, BKVec3d u) { return BKV3dSub(v, BKV3dScale(u, BKV3dDot(v, u))); }

// What: rotates v by the rotation that turns unit direction a into unit direction b (Rodrigues'
// formula about a x b). Parallel directions: no turn. Opposite directions: half a turn about an axis
// perpendicular to a.
static BKVec3d BKCBend(BKVec3d v, BKVec3d a, BKVec3d b)
{
    BKVec3d axis = BKV3dCross(a, b);
    double s = BKV3dLength(axis), c = BKV3dDot(a, b);
    if (s < 1e-15) {
        if (c > 0) return v;
        BKVec3d k = BKCUnit(BKV3dCross(a, fabs(a.x) < 0.9 ? BKV3d(1, 0, 0) : BKV3d(0, 1, 0)));
        return BKV3dSub(BKV3dScale(k, 2.0 * BKV3dDot(k, v)), v);   // 180 degrees about k
    }
    BKVec3d k = BKV3dDiv(axis, s);
    return BKV3dAdd(BKV3dAdd(BKV3dScale(v, c), BKV3dScale(BKV3dCross(k, v), s)), BKV3dScale(k, BKV3dDot(k, v) * (1.0 - c)));
}

// ------------------------------------------------------------------------------------------------
// Spline through the nodes

size_t BKCurveSegmentsFromNodes(const BKVec3d *nodes, size_t count, BKCurveSegment *segments)
{
    if (nodes == NULL || segments == NULL || count < 2) return 0;
    for (size_t i = 0; i < count; i++) {
        if (!BKCFinite(nodes[i])) return 0;
        if (i > 0 && BKV3dDistance(nodes[i], nodes[i - 1]) <= 0) return 0;
    }
    if (count == 2) {   // straight piece
        BKVec3d d = BKV3dSub(nodes[1], nodes[0]);
        segments[0].p0 = nodes[0];
        segments[0].c0 = BKV3dAddScaled(nodes[0], d, 1.0 / 3.0);
        segments[0].c1 = BKV3dAddScaled(nodes[0], d, 2.0 / 3.0);
        segments[0].p1 = nodes[1];
        return 1;
    }

    // Extended node list q[0..m-1]: a mirrored point before the first and after the last node.
    size_t m = count + 2;
    BKVec3d *q = malloc(sizeof(BKVec3d) * m);
    double *h = malloc(sizeof(double) * m);
    BKVec3d *M = malloc(sizeof(BKVec3d) * m);    // second derivatives at q[j] (d2S/ds2)
    double *cp = malloc(sizeof(double) * m);     // Thomas algorithm scratch
    BKVec3d *dp = malloc(sizeof(BKVec3d) * m);
    if (!q || !h || !M || !cp || !dp) { free(q); free(h); free(M); free(cp); free(dp); return 0; }
    for (size_t i = 0; i < count; i++) q[i + 1] = nodes[i];
    q[0] = BKV3dSub(BKV3dScale(nodes[0], 2.0), nodes[1]);
    q[m - 1] = BKV3dSub(BKV3dScale(nodes[count - 1], 2.0), nodes[count - 2]);
    for (size_t j = 0; j + 1 < m; j++) h[j] = BKV3dDistance(q[j + 1], q[j]);

    // Natural spline (M[0] = M[m-1] = 0) with parameter = distance along the polygon:
    // h[j-1] M[j-1] + 2 (h[j-1] + h[j]) M[j] + h[j] M[j+1] = 6 ((q[j+1]-q[j])/h[j] - (q[j]-q[j-1])/h[j-1])
    // for j = 1..m-2, solved with the tridiagonal (Thomas) algorithm for x, y and z at once.
    M[0] = BKV3d(0, 0, 0);
    M[m - 1] = BKV3d(0, 0, 0);
    size_t n = m - 2;   // unknowns M[1..m-2]
    for (size_t k = 0; k < n; k++) {
        size_t j = k + 1;
        double a = (k > 0) ? h[j - 1] : 0.0;           // below-diagonal (M[0] = 0 is known)
        double b = 2.0 * (h[j - 1] + h[j]);
        double c = (k + 1 < n) ? h[j] : 0.0;           // above-diagonal (M[m-1] = 0 is known)
        BKVec3d r = BKV3dScale(BKV3dSub(BKV3dDiv(BKV3dSub(q[j + 1], q[j]), h[j]),
                                        BKV3dDiv(BKV3dSub(q[j], q[j - 1]), h[j - 1])), 6.0);
        if (k == 0) {
            cp[k] = c / b;
            dp[k] = BKV3dDiv(r, b);
        } else {
            double den = b - a * cp[k - 1];
            cp[k] = c / den;
            dp[k] = BKV3dDiv(BKV3dSub(r, BKV3dScale(dp[k - 1], a)), den);
        }
    }
    M[n] = dp[n - 1];
    for (size_t k = n - 1; k-- > 0;) M[k + 1] = BKV3dSub(dp[k], BKV3dScale(M[k + 2], cp[k]));

    // Each piece between real nodes q[j]..q[j+1] (j = 1..m-3) -> one Bezier segment.
    for (size_t j = 1; j + 2 < m; j++) {
        double hj = h[j];
        BKVec3d slope = BKV3dDiv(BKV3dSub(q[j + 1], q[j]), hj);
        BKVec3d d0 = BKV3dSub(slope, BKV3dScale(BKV3dAdd(BKV3dScale(M[j], 2.0), M[j + 1]), hj / 6.0));   // S'(0)
        BKVec3d d1 = BKV3dAdd(slope, BKV3dScale(BKV3dAdd(M[j], BKV3dScale(M[j + 1], 2.0)), hj / 6.0));   // S'(h)
        BKCurveSegment *s = &segments[j - 1];
        s->p0 = q[j];
        s->c0 = BKV3dAddScaled(q[j], d0, hj / 3.0);
        s->c1 = BKV3dAddScaled(q[j + 1], d1, -hj / 3.0);
        s->p1 = q[j + 1];
    }
    free(q); free(h); free(M); free(cp); free(dp);
    return count - 1;
}

BKVec3d BKCurveSegmentPoint(const BKCurveSegment *s, double t)
{
    double u = 1.0 - t;
    return BKV3dAdd(BKV3dAdd(BKV3dScale(s->p0, u * u * u), BKV3dScale(s->c0, 3.0 * u * u * t)),
                    BKV3dAdd(BKV3dScale(s->c1, 3.0 * u * t * t), BKV3dScale(s->p1, t * t * t)));
}

BKVec3d BKCurveSegmentDerivative(const BKCurveSegment *s, double t)
{
    double u = 1.0 - t;
    return BKV3dAdd(BKV3dAdd(BKV3dScale(BKV3dSub(s->c0, s->p0), 3.0 * u * u),
                             BKV3dScale(BKV3dSub(s->c1, s->c0), 6.0 * u * t)),
                    BKV3dScale(BKV3dSub(s->p1, s->c1), 3.0 * t * t));
}

// ------------------------------------------------------------------------------------------------
// Polyline building

typedef struct { BKVec3d *p; size_t n, cap; int failed; } BKCBuf;

static void BKCPush(BKCBuf *b, BKVec3d v)
{
    if (b->failed) return;
    if (b->n > 0 && BKV3dDistance(b->p[b->n - 1], v) <= 0) return;   // drop repeated points
    if (b->n == b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 256;
        BKVec3d *p = realloc(b->p, cap * sizeof(BKVec3d));
        if (!p) { b->failed = 1; return; }
        b->p = p; b->cap = cap;
    }
    b->p[b->n++] = v;
}

// What: the part of segment s between parameters t0 and t1 as its own Bezier segment.
static BKCurveSegment BKCSubSegment(const BKCurveSegment *s, double t0, double t1)
{
    BKCurveSegment r;
    double k = (t1 - t0) / 3.0;
    r.p0 = BKCurveSegmentPoint(s, t0);
    r.p1 = BKCurveSegmentPoint(s, t1);
    r.c0 = BKV3dAddScaled(r.p0, BKCurveSegmentDerivative(s, t0), k);
    r.c1 = BKV3dAddScaled(r.p1, BKCurveSegmentDerivative(s, t1), -k);
    return r;
}

// What: distance from p to the segment a-b.
static double BKCPointSegmentDistance(BKVec3d p, BKVec3d a, BKVec3d b)
{
    BKVec3d ab = BKV3dSub(b, a);
    double l2 = BKV3dDot(ab, ab);
    double t = l2 > 0 ? BKV3dDot(BKV3dSub(p, a), ab) / l2 : 0.0;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return BKV3dDistance(p, BKV3dAddScaled(a, ab, t));
}

static void BKCFlattenPiece(const BKCurveSegment *s, double flatness, int depth, BKCBuf *b)
{
    if (depth >= BK_CURVE_MAX_DEPTH ||
        (BKCPointSegmentDistance(s->c0, s->p0, s->p1) <= flatness && BKCPointSegmentDistance(s->c1, s->p0, s->p1) <= flatness)) {
        BKCPush(b, s->p1);
        return;
    }
    BKCurveSegment left = BKCSubSegment(s, 0.0, 0.5), right = BKCSubSegment(s, 0.5, 1.0);
    BKCFlattenPiece(&left, flatness, depth + 1, b);
    BKCFlattenPiece(&right, flatness, depth + 1, b);
}

int BKCurveFlatten(const BKCurveSegment *segments, size_t segmentCount, double maxSegmentLength,
                   double flatness, BKCurvePolyline *out)
{
    if (out == NULL) return 0;
    out->points = NULL; out->count = 0;
    if (segments == NULL || segmentCount == 0 || !(flatness > 0) || !(maxSegmentLength > 0)) return 0;
    BKCBuf b = { NULL, 0, 0, 0 };
    BKCPush(&b, segments[0].p0);
    for (size_t i = 0; i < segmentCount; i++) {
        const BKCurveSegment *s = &segments[i];
        double polygon = BKV3dDistance(s->p0, s->c0) + BKV3dDistance(s->c0, s->c1) + BKV3dDistance(s->c1, s->p1);
        double piecesD = ceil(polygon / maxSegmentLength);
        size_t pieces = (piecesD < 1 || !isfinite(piecesD)) ? 1 : (size_t)(piecesD > 65536 ? 65536 : piecesD);
        for (size_t k = 0; k < pieces; k++) {
            BKCurveSegment piece = BKCSubSegment(s, (double)k / pieces, (double)(k + 1) / pieces);
            if (k + 1 == pieces) piece.p1 = s->p1;   // exact end node
            BKCFlattenPiece(&piece, flatness, 0, &b);
        }
    }
    if (b.failed || b.n == 0) { free(b.p); return 0; }
    out->points = b.p;
    out->count = b.n;
    return 1;
}

void BKCurvePolylineFree(BKCurvePolyline *polyline)
{
    if (polyline == NULL) return;
    free(polyline->points);
    polyline->points = NULL;
    polyline->count = 0;
}

double BKCurvePolylineLength(const BKCurvePolyline *p)
{
    if (p == NULL || p->points == NULL) return 0;
    double length = 0;
    for (size_t i = 1; i < p->count; i++) length += BKV3dDistance(p->points[i], p->points[i - 1]);
    return length;
}

// ------------------------------------------------------------------------------------------------
// Frames along the polyline

// What: the normal on the first piece (rule in the header).
static BKVec3d BKCFirstNormal(BKVec3d initialNormal, BKVec3d dir)
{
    BKVec3d n = BKCUnit(BKCPerp(initialNormal, dir));
    if (BKV3dLength(n) == 0) n = BKCUnit(BKV3dCross(BKV3d(-1, 0, 0), dir));
    if (BKV3dLength(n) == 0) n = BKCUnit(BKV3dCross(BKV3d(0, 1, 0), dir));
    return n;
}

// What: walker over the pieces, keeping each piece's direction, normal and the corner averages.
typedef struct {
    const BKCurvePolyline *p;
    size_t piece;            // current piece: points[piece] -> points[piece+1]
    double length;           // its length
    BKVec3d dir, normal;     // its unit direction and carried normal
    BKVec3d prevDir, prevNormal, nextDir, nextNormal;
    int hasNext;
} BKCWalk;

static void BKCWalkLookAhead(BKCWalk *w)
{
    const BKCurvePolyline *p = w->p;
    if (w->piece + 2 < p->count) {
        w->nextDir = BKCUnit(BKV3dSub(p->points[w->piece + 2], p->points[w->piece + 1]));
        w->nextNormal = BKCUnit(BKCPerp(BKCBend(w->normal, w->dir, w->nextDir), w->nextDir));
        w->hasNext = 1;
    } else {
        w->nextDir = w->dir;
        w->nextNormal = w->normal;
        w->hasNext = 0;
    }
}

static int BKCWalkStart(BKCWalk *w, const BKCurvePolyline *p, BKVec3d initialNormal)
{
    if (p == NULL || p->points == NULL || p->count < 2) return 0;
    w->p = p;
    w->piece = 0;
    w->length = BKV3dDistance(p->points[1], p->points[0]);
    w->dir = BKCUnit(BKV3dSub(p->points[1], p->points[0]));
    w->normal = BKCFirstNormal(initialNormal, w->dir);
    w->prevDir = w->dir;
    w->prevNormal = w->normal;
    BKCWalkLookAhead(w);
    return 1;
}

static int BKCWalkNext(BKCWalk *w)
{
    if (!w->hasNext) return 0;
    w->prevDir = w->dir;
    w->prevNormal = w->normal;
    w->dir = w->nextDir;
    w->normal = w->nextNormal;
    w->piece++;
    w->length = BKV3dDistance(w->p->points[w->piece + 1], w->p->points[w->piece]);
    BKCWalkLookAhead(w);
    return 1;
}

// What: position / tangent / normal `d` mm into the current piece (0 <= d <= length).
static void BKCWalkFrame(const BKCWalk *w, double d, BKVec3d *pos, BKVec3d *tan, BKVec3d *nor)
{
    double f = w->length > 0 ? d / w->length : 0.0;
    if (pos) *pos = BKV3dAddScaled(w->p->points[w->piece], w->dir, d);
    if (tan) {
        BKVec3d t0 = BKCUnit(BKV3dAdd(w->prevDir, w->dir)), t1 = BKCUnit(BKV3dAdd(w->nextDir, w->dir));
        *tan = BKCUnit(BKV3dAdd(BKV3dScale(t0, 1.0 - f), BKV3dScale(t1, f)));
    }
    if (nor) {
        BKVec3d n0 = BKCUnit(BKV3dAdd(w->prevNormal, w->normal)), n1 = BKCUnit(BKV3dAdd(w->nextNormal, w->normal));
        *nor = BKCUnit(BKV3dAdd(BKV3dScale(n0, 1.0 - f), BKV3dScale(n1, f)));
    }
}

size_t BKCurvePolylineSample(const BKCurvePolyline *polyline, double spacing, double startDistance,
                             BKVec3d initialNormal, BKVec3d *positions, BKVec3d *tangents, BKVec3d *normals,
                             size_t maxSamples)
{
    BKCWalk w;
    if (maxSamples == 0 || !(spacing > 0) || !isfinite(startDistance) || startDistance < 0 ||
        !BKCWalkStart(&w, polyline, initialNormal))
        return 0;
    size_t i = 0;
    double d = startDistance;   // distance into the current piece
    for (;;) {
        while (d < w.length) {
            BKCWalkFrame(&w, d, positions ? &positions[i] : NULL, tangents ? &tangents[i] : NULL,
                         normals ? &normals[i] : NULL);
            if (++i >= maxSamples) return i;
            d += spacing;
        }
        d -= w.length;
        if (!BKCWalkNext(&w)) return i;
    }
}

// What: a unit vector perpendicular to unit d (for a piece seen end-on in projected sampling).
static BKVec3d BKCAnyPerpendicular(BKVec3d d)
{
    BKVec3d r = BKCUnit(BKV3dCross(d, fabs(d.x) < 0.9 ? BKV3d(1, 0, 0) : BKV3d(0, 1, 0)));
    return r;
}

size_t BKCurvePolylineSampleProjected(const BKCurvePolyline *p, double spacing, double startDistance,
                                      BKVec3d projectionDirection, BKVec3d *positions, BKVec3d *tangents,
                                      BKVec3d *normals, double *relativePositions, size_t maxSamples)
{
    if (p == NULL || p->points == NULL || p->count < 2 || maxSamples == 0 || !(spacing > 0) ||
        !isfinite(startDistance) || startDistance < 0)
        return 0;
    BKVec3d proj = BKCUnit(projectionDirection);
    if (BKV3dLength(proj) == 0) return 0;
    double total = BKCurvePolylineLength(p);
    if (!(total > 0)) return 0;
    size_t pieces = p->count - 1;
    // Per piece: real direction / length, projected length, projected normal.
    #define BKC_PIECE(k, dir, len, plen, nor) do { \
        BKVec3d a_ = p->points[(k)], b_ = p->points[(k) + 1], ab_ = BKV3dSub(b_, a_); \
        BKVec3d pab_ = BKCPerp(ab_, proj); \
        (dir) = BKCUnit(ab_); (len) = BKV3dLength(ab_); (plen) = BKV3dLength(pab_); \
        (nor) = BKCUnit(BKV3dCross(BKCUnit(pab_), proj)); \
        if (BKV3dLength(nor) == 0) (nor) = BKCAnyPerpendicular(proj); } while (0)
    BKVec3d dir, nor, nextDir, nextNor, prevDir, prevNor;
    double len, plen, nextLen, nextPlen;
    BKC_PIECE(0, dir, len, plen, nor);
    prevDir = dir; prevNor = nor;
    size_t i = 0;
    double d = startDistance, walked = 0;   // d: projected distance into the current piece
    for (size_t k = 0; k < pieces; k++) {
        if (k + 1 < pieces) BKC_PIECE(k + 1, nextDir, nextLen, nextPlen, nextNor);
        else { nextDir = dir; nextNor = nor; nextLen = len; nextPlen = plen; }
        BKVec3d t0 = BKCUnit(BKV3dAdd(prevDir, dir)), t1 = BKCUnit(BKV3dAdd(nextDir, dir));
        BKVec3d n0 = BKCUnit(BKV3dAdd(prevNor, nor)), n1 = BKCUnit(BKV3dAdd(nextNor, nor));
        while (d < plen) {
            double f = d / plen;            // fraction of the piece
            double real = f * len;
            if (positions) positions[i] = BKV3dAddScaled(p->points[k], dir, real);
            if (tangents) tangents[i] = BKCUnit(BKV3dAdd(BKV3dScale(t0, 1.0 - f), BKV3dScale(t1, f)));
            if (normals) normals[i] = BKCUnit(BKV3dAdd(BKV3dScale(n0, 1.0 - f), BKV3dScale(n1, f)));
            if (relativePositions) relativePositions[i] = (walked + real) / total;
            if (++i >= maxSamples) return i;
            d += spacing;
        }
        d -= plen;
        walked += len;
        prevDir = dir; prevNor = nor;
        dir = nextDir; nor = nextNor; len = nextLen; plen = nextPlen;
    }
    #undef BKC_PIECE
    return i;
}

int BKCurvePolylineSampleAt(const BKCurvePolyline *polyline, double distance, BKVec3d initialNormal,
                            BKVec3d *position, BKVec3d *tangent, BKVec3d *normal)
{
    BKCWalk w;
    if (!BKCWalkStart(&w, polyline, initialNormal)) {
        if (polyline && polyline->count == 1 && position) { *position = polyline->points[0]; return 1; }
        return 0;
    }
    double d = isfinite(distance) && distance > 0 ? distance : 0.0;
    while (d >= w.length) {
        double left = w.length;   // the piece being left
        if (!BKCWalkNext(&w)) {   // past the end: the end of the last piece
            BKCWalkFrame(&w, w.length, position, tangent, normal);
            return 1;
        }
        d -= left;
    }
    BKCWalkFrame(&w, d, position, tangent, normal);
    return 1;
}

// ------------------------------------------------------------------------------------------------
// Closest points

double BKCurvePolylineClosestToPoint(const BKCurvePolyline *p, BKVec3d point, BKVec3d *closest, double *distance)
{
    if (p == NULL || p->points == NULL || p->count == 0) return 0;
    double total = BKCurvePolylineLength(p), walked = 0, best = INFINITY, bestAt = 0;
    BKVec3d bestPoint = p->points[0];
    if (p->count == 1) best = BKV3dDistance(point, p->points[0]);
    for (size_t i = 1; i < p->count; i++) {
        BKVec3d a = p->points[i - 1], ab = BKV3dSub(p->points[i], a);
        double l2 = BKV3dDot(ab, ab), l = sqrt(l2);
        double t = l2 > 0 ? BKV3dDot(BKV3dSub(point, a), ab) / l2 : 0.0;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        BKVec3d c = BKV3dAddScaled(a, ab, t);
        double dist = BKV3dDistance(point, c);
        if (dist < best) { best = dist; bestPoint = c; bestAt = walked + t * l; }
        walked += l;
    }
    if (closest) *closest = bestPoint;
    if (distance) *distance = best;
    return total > 0 ? bestAt / total : 0.0;
}

double BKCurvePolylineClosestToLine(const BKCurvePolyline *p, BKVec3d linePoint, BKVec3d lineDirection,
                                    BKVec3d *closest, double *distance)
{
    if (p == NULL || p->points == NULL || p->count == 0) return 0;
    BKVec3d u = BKCUnit(lineDirection);
    if (BKV3dLength(u) == 0) return BKCurvePolylineClosestToPoint(p, linePoint, closest, distance);
    double total = BKCurvePolylineLength(p), walked = 0, best = INFINITY, bestAt = 0;
    BKVec3d bestPoint = p->points[0];
    for (size_t i = 1; i < p->count; i++) {
        BKVec3d a = p->points[i - 1], ab = BKV3dSub(p->points[i], a);
        double l = BKV3dLength(ab);
        // Closest pair segment / infinite line: minimise |a + t ab - (L + s u)| over t in [0,1].
        BKVec3d w0 = BKV3dSub(a, linePoint);
        double A = BKV3dDot(ab, ab), B = BKV3dDot(ab, u), D = BKV3dDot(ab, w0), E = BKV3dDot(u, w0);
        double den = A - B * B;   // (u is unit)
        double t = den > 1e-18 ? (B * E - D) / den : 0.0;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        BKVec3d c = BKV3dAddScaled(a, ab, t);
        BKVec3d rel = BKV3dSub(c, linePoint);
        double dist = BKV3dLength(BKCPerp(rel, u));
        if (dist < best) { best = dist; bestPoint = c; bestAt = walked + t * l; }
        walked += l;
    }
    if (closest) *closest = bestPoint;
    if (distance) *distance = best;
    return total > 0 ? bestAt / total : 0.0;
}

// ------------------------------------------------------------------------------------------------
// Copies

static int BKCCopy(const BKCurvePolyline *p, BKCurvePolyline *out)
{
    out->points = NULL; out->count = 0;
    if (p == NULL || p->points == NULL) return 0;
    out->points = malloc(sizeof(BKVec3d) * (p->count ? p->count : 1));
    if (!out->points) return 0;
    memcpy(out->points, p->points, sizeof(BKVec3d) * p->count);
    out->count = p->count;
    return 1;
}

int BKCurvePolylineSplitAtPlane(const BKCurvePolyline *p, BKVec3d planePoint, BKVec3d planeNormal,
                                BKCurvePolyline *out)
{
    if (out == NULL) return 0;
    out->points = NULL; out->count = 0;
    if (p == NULL || p->points == NULL || p->count == 0) return 0;
    BKVec3d n = BKCUnit(planeNormal);
    BKCBuf b = { NULL, 0, 0, 0 };
    BKCPush(&b, p->points[0]);
    for (size_t i = 1; i < p->count; i++) {
        double s0 = BKV3dDot(BKV3dSub(p->points[i - 1], planePoint), n);
        double s1 = BKV3dDot(BKV3dSub(p->points[i], planePoint), n);
        if ((s0 < 0 && s1 > 0) || (s0 > 0 && s1 < 0)) {
            double t = s0 / (s0 - s1);
            BKCPush(&b, BKV3dAdd(p->points[i - 1], BKV3dScale(BKV3dSub(p->points[i], p->points[i - 1]), t)));
        }
        BKCPush(&b, p->points[i]);
    }
    if (b.failed) { free(b.p); return 0; }
    out->points = b.p; out->count = b.n;
    return 1;
}

size_t BKCurvePolylinePlaneIntersections(const BKCurvePolyline *p, BKVec3d planePoint, BKVec3d planeNormal,
                                         BKVec3d *points, double *relativePositions, size_t maxResults)
{
    if (p == NULL || p->points == NULL || p->count == 0 || maxResults == 0) return 0;
    BKVec3d n = BKCUnit(planeNormal);
    if (BKV3dLength(n) == 0) return 0;
    double total = BKCurvePolylineLength(p), walked = 0;
    size_t found = 0;
    #define BKC_EMIT(v, at) do { if (points) points[found] = (v); \
        if (relativePositions) relativePositions[found] = total > 0 ? (at) / total : 0.0; \
        if (++found >= maxResults) return found; } while (0)
    double s0 = BKV3dDot(BKV3dSub(p->points[0], planePoint), n);
    if (s0 == 0) BKC_EMIT(p->points[0], 0.0);
    for (size_t i = 1; i < p->count; i++) {
        BKVec3d a = p->points[i - 1], b = p->points[i];
        double l = BKV3dDistance(a, b);
        double s1 = BKV3dDot(BKV3dSub(b, planePoint), n);
        if ((s0 < 0 && s1 > 0) || (s0 > 0 && s1 < 0)) {
            double t = s0 / (s0 - s1);
            BKC_EMIT(BKV3dAdd(a, BKV3dScale(BKV3dSub(b, a), t)), walked + t * l);
        }
        if (s1 == 0) BKC_EMIT(b, walked + l);
        walked += l;
        s0 = s1;
    }
    #undef BKC_EMIT
    return found;
}

int BKCurvePolylineOutline(const BKCurvePolyline *p, double distance, double spacing, BKVec3d initialNormal,
                           BKCurvePolyline *out)
{
    if (out == NULL) return 0;
    out->points = NULL; out->count = 0;
    double length = BKCurvePolylineLength(p);
    if (!(spacing > 0) || !isfinite(distance) || !(length > 0)) return 0;
    size_t max = (size_t)(length / spacing) + 2;
    BKVec3d *pos = malloc(sizeof(BKVec3d) * max), *nor = malloc(sizeof(BKVec3d) * max);
    if (!pos || !nor) { free(pos); free(nor); return 0; }
    size_t n = BKCurvePolylineSample(p, spacing, 0, initialNormal, pos, NULL, nor, max - 1);
    BKCurvePolylineSampleAt(p, length, initialNormal, &pos[n], NULL, &nor[n]);   // include the end
    n++;
    for (size_t i = 0; i < n; i++) pos[i] = BKV3dAddScaled(pos[i], nor[i], distance);
    free(nor);
    out->points = pos; out->count = n;
    return 1;
}

int BKCurvePolylineProjectToPlane(const BKCurvePolyline *p, BKVec3d planePoint, BKVec3d planeNormal,
                                  BKCurvePolyline *out)
{
    if (out == NULL || !BKCCopy(p, out)) return 0;
    BKVec3d n = BKCUnit(planeNormal);
    for (size_t i = 0; i < out->count; i++)
        out->points[i] = BKV3dSub(out->points[i], BKV3dScale(n, BKV3dDot(BKV3dSub(out->points[i], planePoint), n)));
    return 1;
}

// ------------------------------------------------------------------------------------------------
// Planes

int BKCurvePolylineBoundingPlanes(const BKCurvePolyline *p, BKVec3d normal, BKVec3d *topPoint, BKVec3d *bottomPoint)
{
    if (p == NULL || p->points == NULL || p->count == 0) return 0;
    BKVec3d n = BKCUnit(normal);
    if (BKV3dLength(n) == 0) return 0;
    size_t top = 0, bottom = 0;
    for (size_t i = 1; i < p->count; i++) {
        double d = BKV3dDot(p->points[i], n);
        if (d > BKV3dDot(p->points[top], n)) top = i;
        if (d < BKV3dDot(p->points[bottom], n)) bottom = i;
    }
    if (topPoint) *topPoint = p->points[top];
    if (bottomPoint) *bottomPoint = p->points[bottom];
    return 1;
}

// What: eigenvector of the smallest eigenvalue of a symmetric 3x3 matrix (cyclic Jacobi rotations).
static BKVec3d BKCSmallestEigenvector(double a[3][3])
{
    double v[3][3] = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    for (int sweep = 0; sweep < 50; sweep++) {
        double off = fabs(a[0][1]) + fabs(a[0][2]) + fabs(a[1][2]);
        if (off < 1e-15) break;
        for (int p = 0; p < 2; p++)
            for (int q = p + 1; q < 3; q++) {
                if (fabs(a[p][q]) < 1e-300) continue;
                double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
                double t = (theta >= 0 ? 1.0 : -1.0) / (fabs(theta) + sqrt(theta * theta + 1.0));
                double c = 1.0 / sqrt(t * t + 1.0), s = t * c;
                for (int k = 0; k < 3; k++) {   // A = J^T A J
                    double akp = a[k][p], akq = a[k][q];
                    a[k][p] = c * akp - s * akq;
                    a[k][q] = s * akp + c * akq;
                }
                for (int k = 0; k < 3; k++) {
                    double apk = a[p][k], aqk = a[q][k];
                    a[p][k] = c * apk - s * aqk;
                    a[q][k] = s * apk + c * aqk;
                }
                for (int k = 0; k < 3; k++) {
                    double vkp = v[k][p], vkq = v[k][q];
                    v[k][p] = c * vkp - s * vkq;
                    v[k][q] = s * vkp + c * vkq;
                }
            }
    }
    int m = 0;
    for (int i = 1; i < 3; i++) if (a[i][i] < a[m][m]) m = i;
    return BKCUnit(BKV3d(v[0][m], v[1][m], v[2][m]));
}

int BKCurvePolylineLeastSquaresPlane(const BKCurvePolyline *p, BKVec3d *point, BKVec3d *normal)
{
    if (p == NULL || p->points == NULL || p->count < 3) return 0;
    BKVec3d c = BKV3d(0, 0, 0);
    for (size_t i = 0; i < p->count; i++) c = BKV3dAdd(c, p->points[i]);
    c = BKV3dDiv(c, (double)p->count);
    double a[3][3] = { { 0 } };
    for (size_t i = 0; i < p->count; i++) {
        BKVec3d d = BKV3dSub(p->points[i], c);
        double e[3] = { d.x, d.y, d.z };
        for (int r = 0; r < 3; r++) for (int k = 0; k < 3; k++) a[r][k] += e[r] * e[k];
    }
    if (point) *point = c;
    if (normal) *normal = BKCSmallestEigenvector(a);
    return 1;
}

int BKCurvePolylineIsPlanar(const BKCurvePolyline *p, double tolerance)
{
    BKVec3d c, n;
    if (p != NULL && p->count < 3 && p->count > 0) return 1;
    if (!BKCurvePolylineLeastSquaresPlane(p, &c, &n)) return 0;
    for (size_t i = 0; i < p->count; i++)
        if (fabs(BKV3dDot(BKV3dSub(p->points[i], c), n)) > tolerance) return 0;
    return 1;
}
