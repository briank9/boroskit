// BorosKitDisplay: BKOverlayCore - see BKOverlayCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// How strokes are built (plain language): for a line through points P0..Pn, two "rails" are made at
// half the line width on either side. At a corner the two rails of the neighbouring pieces are joined
// at their crossing point (miter), or - when that point would stick out too far - by a straight cut
// across the corner (bevel). The band between the rails is cut into triangles. For smooth edges the
// solid band is half a pixel narrower on each side and a one-pixel band whose outer edge has zero
// alpha is added outside it, so the edge fades over one pixel centred on the true edge.

#include "BKOverlayCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct BKOverlayList {
    BKOverlayVertex *v; uint32_t vCount, vCap;
    BKOverlayCommand *c; uint32_t cCount, cCap;
    BKOverlayImage *img; uint32_t imgCount, imgCap;
    int error;
    int ignoreAlpha;
    int hasClip; int32_t clip[4];
};

// --- small helpers --------------------------------------------------------------------------------
static BKVec2f V2(float x, float y) { BKVec2f r = { x, y }; return r; }
static BKVec2f Add(BKVec2f a, BKVec2f b) { return V2(a.x + b.x, a.y + b.y); }
static BKVec2f Sub(BKVec2f a, BKVec2f b) { return V2(a.x - b.x, a.y - b.y); }
static BKVec2f Mul(BKVec2f a, float s) { return V2(a.x * s, a.y * s); }
static float Dot(BKVec2f a, BKVec2f b) { return a.x * b.x + a.y * b.y; }
static float Len(BKVec2f a) { return sqrtf(a.x * a.x + a.y * a.y); }
static BKVec2f Unit(BKVec2f a) { float l = Len(a); return l > 0 ? Mul(a, 1.0f / l) : V2(0, 0); }
static BKVec2f Perp(BKVec2f d) { return V2(-d.y, d.x); }   // left normal of a direction (y down: points "right")
static int Finite2(BKVec2f p) { return isfinite(p.x) && isfinite(p.y); }
static BKOverlayColor Mix(BKOverlayColor a, BKOverlayColor b, float t)
{
    BKOverlayColor r = { a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t };
    return r;
}
static BKOverlayColor WithAlpha(BKOverlayColor c, float k) { c.a *= k; return c; }

static int Grow(void **p, uint32_t *cap, uint32_t need, size_t item)
{
    if (need <= *cap) return 1;
    uint32_t n = *cap ? *cap : 256;
    while (n < need) n *= 2;
    void *q = realloc(*p, (size_t)n * item);
    if (!q) return 0;
    *p = q; *cap = n;
    return 1;
}

// --- list -------------------------------------------------------------------------------------------
BKOverlayList *BKOverlayListCreate(void) { return (BKOverlayList *)calloc(1, sizeof(BKOverlayList)); }

void BKOverlayListReset(BKOverlayList *l)
{
    if (!l) return;
    for (uint32_t i = 0; i < l->imgCount; i++) free(l->img[i].pixels);
    l->vCount = l->cCount = l->imgCount = 0;
    l->error = 0; l->ignoreAlpha = 0; l->hasClip = 0;
}

void BKOverlayListFree(BKOverlayList *l)
{
    if (!l) return;
    BKOverlayListReset(l);
    free(l->v); free(l->c); free(l->img); free(l);
}

const BKOverlayVertex *BKOverlayListVertices(const BKOverlayList *l, uint32_t *n) { if (n) *n = l ? l->vCount : 0; return l ? l->v : NULL; }
const BKOverlayCommand *BKOverlayListCommands(const BKOverlayList *l, uint32_t *n) { if (n) *n = l ? l->cCount : 0; return l ? l->c : NULL; }
const BKOverlayImage *BKOverlayListImages(const BKOverlayList *l, uint32_t *n) { if (n) *n = l ? l->imgCount : 0; return l ? l->img : NULL; }
int BKOverlayListError(const BKOverlayList *l) { return l ? l->error : 2; }

void BKOverlaySetClip(BKOverlayList *l, int32_t x, int32_t y, int32_t w, int32_t h)
{
    if (!l) return;
    l->hasClip = (w > 0 && h > 0);
    l->clip[0] = x; l->clip[1] = y; l->clip[2] = w; l->clip[3] = h;
}

void BKOverlaySetIgnoreAlpha(BKOverlayList *l, int ignore) { if (l) l->ignoreAlpha = ignore ? 1 : 0; }

// What: the command new triangles go into (the last one when it has the same settings, else a new one).
static BKOverlayCommand *Command(BKOverlayList *l, int mode, int image, int linear)
{
    if (l->cCount) {
        BKOverlayCommand *c = &l->c[l->cCount - 1];
        if (c->mode == mode && c->image == image && c->linearFilter == linear && c->ignoreAlpha == l->ignoreAlpha &&
            c->hasClip == l->hasClip && (!l->hasClip || (c->clipX == l->clip[0] && c->clipY == l->clip[1] &&
                                                         c->clipW == l->clip[2] && c->clipH == l->clip[3])) &&
            c->first + c->count == l->vCount)
            return c;
    }
    if (!Grow((void **)&l->c, &l->cCap, l->cCount + 1, sizeof(BKOverlayCommand))) { l->error = 1; return NULL; }
    BKOverlayCommand *c = &l->c[l->cCount++];
    memset(c, 0, sizeof(*c));
    c->first = l->vCount; c->mode = mode; c->image = image; c->linearFilter = linear; c->ignoreAlpha = l->ignoreAlpha;
    c->hasClip = l->hasClip;
    if (l->hasClip) { c->clipX = l->clip[0]; c->clipY = l->clip[1]; c->clipW = l->clip[2]; c->clipH = l->clip[3]; }
    return c;
}

// Appends one triangle (positions, texture coordinates, colours) to the current command.
static void Tri(BKOverlayList *l, BKOverlayCommand *cmd,
                BKVec2f a, BKVec2f b, BKVec2f c, BKOverlayColor ca, BKOverlayColor cb, BKOverlayColor cc,
                BKVec2f ta, BKVec2f tb, BKVec2f tc)
{
    if (!cmd) return;
    if (!Grow((void **)&l->v, &l->vCap, l->vCount + 3, sizeof(BKOverlayVertex))) { l->error = 1; return; }
    BKOverlayVertex *v = &l->v[l->vCount];
    BKVec2f p[3] = { a, b, c }, t[3] = { ta, tb, tc };
    BKOverlayColor k[3] = { ca, cb, cc };
    for (int i = 0; i < 3; i++) {
        v[i].x = p[i].x; v[i].y = p[i].y; v[i].u = t[i].x; v[i].v = t[i].y;
        v[i].r = k[i].r; v[i].g = k[i].g; v[i].b = k[i].b; v[i].a = k[i].a;
    }
    l->vCount += 3;
    cmd->count += 3;
}

static void SolidTri(BKOverlayList *l, BKOverlayCommand *cmd, BKVec2f a, BKVec2f b, BKVec2f c,
                     BKOverlayColor ca, BKOverlayColor cb, BKOverlayColor cc)
{
    BKVec2f z = V2(0, 0);
    Tri(l, cmd, a, b, c, ca, cb, cc, z, z, z);
}

// Quad a-b-c-d (in order around) as two triangles.
static void SolidQuad(BKOverlayList *l, BKOverlayCommand *cmd, BKVec2f a, BKVec2f b, BKVec2f c, BKVec2f d,
                      BKOverlayColor ca, BKOverlayColor cb, BKOverlayColor cc, BKOverlayColor cd)
{
    SolidTri(l, cmd, a, b, c, ca, cb, cc);
    SolidTri(l, cmd, a, c, d, ca, cc, cd);
}

// --- strokes ----------------------------------------------------------------------------------------
// One rail point: position on the solid band edge, the outward direction of its fringe, and colour.
typedef struct { BKVec2f p; BKVec2f out; BKOverlayColor c; } Rail;

// What: strokes one OPEN or CLOSED run of distinct points (no dashes here) - rails, joins, caps, fringe.
static void StrokeRun(BKOverlayList *l, BKOverlayCommand *cmd, const BKVec2f *P, const BKOverlayColor *C,
                      uint32_t n, int closed, const BKOverlayStroke *s)
{
    if (n < 2) return;
    float w = s->width > 1.0f / 64 ? s->width : 1.0f / 64;
    int smooth = s->smooth;
    // Solid half width and coverage: smooth edges fade over one pixel centred on the true edge.
    float h = smooth ? w * 0.5f - 0.5f : w * 0.5f;
    float cover = 1.0f;
    if (smooth && h < 0) { cover = w; h = 0; }   // thinner than a pixel: fainter, as coverage would be
    float limit = s->miterLimit > 1.0f ? s->miterLimit : 10.0f;
    uint32_t segs = closed ? n : n - 1;

    // Square caps on open runs: move the end points outward by half the width.
    BKVec2f first = P[0], last = P[n - 1];
    if (!closed && s->cap == BKOverlayCapSquare) {
        first = Sub(P[0], Mul(Unit(Sub(P[1], P[0])), w * 0.5f));
        last = Add(P[n - 1], Mul(Unit(Sub(P[n - 1], P[n - 2])), w * 0.5f));
    }
    // Smooth butt / square ends: the solid band stops half a pixel short of the end, the fringe covers it.
    if (!closed && smooth) {
        first = Add(first, Mul(Unit(Sub(P[1], P[0])), 0.5f));
        last = Sub(last, Mul(Unit(Sub(P[n - 1], P[n - 2])), 0.5f));
    }

    // Rails: for every vertex one (or two, at a bevel) point pairs (left, right).
    size_t maxPairs = (size_t)(n + 1) * 2;
    Rail *L = (Rail *)malloc(sizeof(Rail) * maxPairs), *R = (Rail *)malloc(sizeof(Rail) * maxPairs);
    if (!L || !R) { free(L); free(R); l->error = 1; return; }
    uint32_t m = 0;
    uint32_t vcount = closed ? n + 1 : n;   // closed: the first vertex again at the end
    for (uint32_t k = 0; k < vcount; k++) {
        uint32_t i = k % n;
        BKVec2f p = (k == 0 && !closed) ? first : ((k == vcount - 1 && !closed) ? last : P[i]);
        BKOverlayColor col = WithAlpha(C[i], cover);
        int hasPrev = closed || k > 0, hasNext = closed || k + 1 < vcount;
        BKVec2f dPrev = hasPrev ? Unit(Sub(P[i], P[(i + n - 1) % n])) : V2(0, 0);
        BKVec2f dNext = hasNext ? Unit(Sub(P[(i + 1) % n], P[i])) : V2(0, 0);
        if (!hasPrev) dPrev = dNext;
        if (!hasNext) dNext = dPrev;
        BKVec2f nPrev = Perp(dPrev), nNext = Perp(dNext);
        BKVec2f bis = Unit(Add(nPrev, nNext));
        float cosHalf = Dot(bis, nNext);
        if (Len(bis) == 0 || cosHalf < 1e-4f) {   // straight back on itself: treat as a flat end
            bis = nNext; cosHalf = 1;
        }
        float miter = 1.0f / cosHalf;
        int straight = fabsf(Dot(dPrev, nNext)) < 1e-6f;
        if (straight || (s->join == BKOverlayJoinMiter && miter <= limit)) {
            L[m].p = Add(p, Mul(bis, h * miter)); L[m].out = bis; L[m].c = col;
            R[m].p = Sub(p, Mul(bis, h * miter)); R[m].out = Mul(bis, -1); R[m].c = col;
            m++;
        } else {
            // Bevel (or round, approximated by a fan between the two outer points): the outer side gets
            // the end of each piece's rail, the inner side the crossing point (kept within the limit).
            int leftOuter = Dot(dNext, nPrev) < 0;   // the next piece turns away from the left rail
            float inner = miter < limit ? miter : limit;
            BKVec2f in = leftOuter ? Sub(p, Mul(bis, h * inner)) : Add(p, Mul(bis, h * inner));
            BKVec2f inOut = leftOuter ? Mul(bis, -1) : bis;
            BKVec2f o1 = leftOuter ? Add(p, Mul(nPrev, h)) : Sub(p, Mul(nPrev, h));
            BKVec2f o2 = leftOuter ? Add(p, Mul(nNext, h)) : Sub(p, Mul(nNext, h));
            BKVec2f out1 = leftOuter ? nPrev : Mul(nPrev, -1), out2 = leftOuter ? nNext : Mul(nNext, -1);
            int steps = 1;
            if (s->join == BKOverlayJoinRound) {
                float ang = acosf(fmaxf(-1.0f, fminf(1.0f, Dot(nPrev, nNext))));
                steps = (int)ceilf(ang / 0.35f); if (steps < 1) steps = 1; if (steps > 16) steps = 16;
            }
            for (int st = 0; st <= steps; st++) {
                float t = (float)st / (float)steps;
                BKVec2f dir = Unit(Add(Mul(out1, 1 - t), Mul(out2, t)));
                BKVec2f o = (steps == 1) ? (st == 0 ? o1 : o2) : Add(p, Mul(dir, h));
                BKVec2f oo = (steps == 1) ? (st == 0 ? out1 : out2) : dir;
                Rail outer = { o, oo, col }, innerRail = { in, inOut, col };
                if (leftOuter) { L[m] = outer; R[m] = innerRail; } else { L[m] = innerRail; R[m] = outer; }
                m++;
                if (m >= maxPairs) break;
            }
        }
        if (m >= maxPairs) break;
    }

    // Solid band and fringes.
    for (uint32_t j = 0; j + 1 < m; j++) {
        SolidQuad(l, cmd, L[j].p, L[j + 1].p, R[j + 1].p, R[j].p, L[j].c, L[j + 1].c, R[j + 1].c, R[j].c);
        if (smooth) {
            BKOverlayColor l0 = WithAlpha(L[j].c, 0), l1 = WithAlpha(L[j + 1].c, 0);
            BKOverlayColor r0 = WithAlpha(R[j].c, 0), r1 = WithAlpha(R[j + 1].c, 0);
            SolidQuad(l, cmd, L[j].p, Add(L[j].p, L[j].out), Add(L[j + 1].p, L[j + 1].out), L[j + 1].p,
                      L[j].c, l0, l1, L[j + 1].c);
            SolidQuad(l, cmd, R[j].p, R[j + 1].p, Add(R[j + 1].p, R[j + 1].out), Add(R[j].p, R[j].out),
                      R[j].c, R[j + 1].c, r1, r0);
        }
    }
    // Smooth open ends: a one-pixel fringe across each end.
    if (smooth && !closed && m >= 2) {
        BKVec2f d0 = Unit(Sub(P[1], P[0])), d1 = Unit(Sub(P[n - 1], P[n - 2]));
        BKVec2f e0 = Mul(d0, -1.0f), e1 = d1;
        SolidQuad(l, cmd, L[0].p, R[0].p, Add(Add(R[0].p, e0), R[0].out), Add(Add(L[0].p, e0), L[0].out),
                  L[0].c, R[0].c, WithAlpha(R[0].c, 0), WithAlpha(L[0].c, 0));
        SolidQuad(l, cmd, L[m - 1].p, Add(Add(L[m - 1].p, e1), L[m - 1].out), Add(Add(R[m - 1].p, e1), R[m - 1].out), R[m - 1].p,
                  L[m - 1].c, WithAlpha(L[m - 1].c, 0), WithAlpha(R[m - 1].c, 0), R[m - 1].c);
    }
    free(L); free(R);
    (void)segs;
}

// Round caps: a dot of the line's width at each open end (drawn after the line).
static void RoundCaps(BKOverlayList *l, const BKVec2f *P, const BKOverlayColor *C, uint32_t n, const BKOverlayStroke *s)
{
    BKVec2f ends[2] = { P[0], P[n - 1] };
    BKOverlayColor cols[2] = { C[0], C[n - 1] };
    BKOverlayPoints(l, ends, cols, 2, s->width, 1, s->smooth, cols[0]);
}

// What: removes non-finite points and repeats (a zero-length piece has no direction); colours follow.
static uint32_t Clean(const BKVec2f *pts, const BKOverlayColor *cols, uint32_t count, BKOverlayColor color,
                      BKVec2f *P, BKOverlayColor *C)
{
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!Finite2(pts[i])) continue;
        if (n && pts[i].x == P[n - 1].x && pts[i].y == P[n - 1].y) continue;
        P[n] = pts[i]; C[n] = cols ? cols[i] : color; n++;
    }
    return n;
}

// What: strokes a clean run, splitting it into dashes first when the stroke has a dash pattern.
static void StrokeCleanRun(BKOverlayList *l, BKOverlayCommand *cmd, const BKVec2f *P, const BKOverlayColor *C,
                           uint32_t n, int closed, const BKOverlayStroke *s)
{
    if (closed && n >= 2 && P[0].x == P[n - 1].x && P[0].y == P[n - 1].y) n--;   // closing point given twice
    if (n < 2) return;
    float pattern = 0;
    for (uint32_t i = 0; i < s->dashCount && s->dashes; i++) pattern += s->dashes[i] > 0 ? s->dashes[i] : 0;
    if (!s->dashes || s->dashCount == 0 || pattern <= 0) {
        StrokeRun(l, cmd, P, C, n, closed, s);
        if (!closed && s->cap == BKOverlayCapRound) RoundCaps(l, P, C, n, s);
        return;
    }
    // Walk the run: "on" stretches become separate open runs (butt / square / round ends as asked).
    uint32_t segs = closed ? n : n - 1;
    BKVec2f *D = (BKVec2f *)malloc(sizeof(BKVec2f) * (n + 2) * 2);
    BKOverlayColor *DC = (BKOverlayColor *)malloc(sizeof(BKOverlayColor) * (n + 2) * 2);
    if (!D || !DC) { free(D); free(DC); l->error = 1; return; }
    float phase = fmodf(s->dashPhase, pattern); if (phase < 0) phase += pattern;
    uint32_t di = 0; float left = 0;
    // position in the pattern
    while (1) { float len = s->dashes[di] > 0 ? s->dashes[di] : 0; if (phase < len) { left = len - phase; break; } phase -= len; di = (di + 1) % s->dashCount; }
    int on = (di % 2) == 0;
    uint32_t dn = 0;
    if (on) { D[dn] = P[0]; DC[dn] = C[0]; dn++; }
    for (uint32_t sgi = 0; sgi < segs; sgi++) {
        BKVec2f a = P[sgi], b = P[(sgi + 1) % n];
        BKOverlayColor ca = C[sgi], cb = C[(sgi + 1) % n];
        float segLen = Len(Sub(b, a)), pos = 0;
        while (segLen - pos > left) {
            pos += left;
            float t = segLen > 0 ? pos / segLen : 0;
            BKVec2f q = Add(a, Mul(Sub(b, a), t));
            BKOverlayColor cq = Mix(ca, cb, t);
            if (on) {
                D[dn] = q; DC[dn] = cq; dn++;
                BKOverlayStroke open = *s; open.dashes = NULL; open.dashCount = 0;
                StrokeCleanRun(l, cmd, D, DC, dn, 0, &open);
                dn = 0;
            } else {
                D[0] = q; DC[0] = cq; dn = 1;
            }
            on = !on;
            di = (di + 1) % s->dashCount;
            left = s->dashes[di] > 0 ? s->dashes[di] : 0;
            if (left <= 0 && pattern <= 0) break;
        }
        left -= (segLen - pos);
        if (on) {
            if (dn >= (n + 2) * 2 - 1) {   // very long dash: flush and continue from here
                BKOverlayStroke open = *s; open.dashes = NULL; open.dashCount = 0;
                StrokeCleanRun(l, cmd, D, DC, dn, 0, &open);
                D[0] = D[dn - 1]; DC[0] = DC[dn - 1]; dn = 1;
            }
            D[dn] = b; DC[dn] = cb; dn++;
        }
    }
    if (on && dn >= 2) {
        BKOverlayStroke open = *s; open.dashes = NULL; open.dashCount = 0;
        StrokeCleanRun(l, cmd, D, DC, dn, 0, &open);
    }
    free(D); free(DC);
}

void BKOverlayStrokePolyline(BKOverlayList *l, const BKVec2f *points, const BKOverlayColor *colors,
                             uint32_t count, int closed, const BKOverlayStroke *stroke, BKOverlayColor color)
{
    if (!l) return;
    if (!points || !stroke || count == 0) { l->error = l->error ? l->error : 2; return; }
    BKVec2f *P = (BKVec2f *)malloc(sizeof(BKVec2f) * count);
    BKOverlayColor *C = (BKOverlayColor *)malloc(sizeof(BKOverlayColor) * count);
    if (!P || !C) { free(P); free(C); l->error = 1; return; }
    uint32_t n = Clean(points, colors, count, color, P, C);
    BKOverlayCommand *cmd = Command(l, BKOverlayModeSolid, -1, 0);
    StrokeCleanRun(l, cmd, P, C, n, closed, stroke);
    free(P); free(C);
}

void BKOverlayStrokeSegments(BKOverlayList *l, const BKVec2f *points, const BKOverlayColor *colors,
                             uint32_t count, const BKOverlayStroke *stroke, BKOverlayColor color)
{
    if (!l) return;
    if (!points || !stroke) { l->error = l->error ? l->error : 2; return; }
    for (uint32_t i = 0; i + 1 < count; i += 2)
        BKOverlayStrokePolyline(l, points + i, colors ? colors + i : NULL, 2, 0, stroke, color);
}

// --- fills ------------------------------------------------------------------------------------------
static float SignedArea(const BKVec2f *P, uint32_t n)
{
    double a = 0;
    for (uint32_t i = 0; i < n; i++) { BKVec2f p = P[i], q = P[(i + 1) % n]; a += (double)p.x * q.y - (double)q.x * p.y; }
    return (float)(a * 0.5);
}

// One-pixel soft rim outside a filled outline (fades from the colour to transparent).
static void FillFringe(BKOverlayList *l, BKOverlayCommand *cmd, const BKVec2f *P, const BKOverlayColor *C, uint32_t n)
{
    float orient = SignedArea(P, n) >= 0 ? 1.0f : -1.0f;
    for (uint32_t i = 0; i < n; i++) {
        BKVec2f a = P[i], b = P[(i + 1) % n];
        BKVec2f d = Unit(Sub(b, a));
        if (Len(d) == 0) continue;
        // Outward normal: with y down, a positive signed area runs clockwise on screen.
        BKVec2f o = Mul(Perp(d), -orient);
        SolidQuad(l, cmd, a, b, Add(b, o), Add(a, o), C[i], C[(i + 1) % n], WithAlpha(C[(i + 1) % n], 0), WithAlpha(C[i], 0));
    }
}

// Even-odd fill by horizontal bands: between consecutive "event" heights (vertices and edge
// crossings) no two edges cross, so the edges cut the band into trapezoids; every second gap is inside.
typedef struct { BKVec2f a, b; } Edge;
static int CmpFloat(const void *x, const void *y) { float a = *(const float *)x, b = *(const float *)y; return (a > b) - (a < b); }
typedef struct { float xm, x0, x1; } Cut;
static int CmpCut(const void *x, const void *y) { float a = ((const Cut *)x)->xm, b = ((const Cut *)y)->xm; return (a > b) - (a < b); }

static void FillEvenOdd(BKOverlayList *l, BKOverlayCommand *cmd, const BKVec2f *P, uint32_t n, BKOverlayColor color)
{
    Edge *E = (Edge *)malloc(sizeof(Edge) * n);
    if (!E) { l->error = 1; return; }
    uint32_t ne = 0;
    for (uint32_t i = 0; i < n; i++) {
        BKVec2f a = P[i], b = P[(i + 1) % n];
        if (a.y == b.y) continue;   // horizontal edges do not cut bands
        if (a.y > b.y) { BKVec2f t = a; a = b; b = t; }
        E[ne].a = a; E[ne].b = b; ne++;
    }
    size_t maxY = (size_t)n + (size_t)ne * (ne > 1 ? ne - 1 : 0) / 2;
    float *Y = (float *)malloc(sizeof(float) * (maxY + 1));
    Cut *cut = (Cut *)malloc(sizeof(Cut) * (ne + 1));
    if (!Y || !cut) { free(E); free(Y); free(cut); l->error = 1; return; }
    size_t ny = 0;
    for (uint32_t i = 0; i < n; i++) Y[ny++] = P[i].y;
    for (uint32_t i = 0; i < ne; i++)
        for (uint32_t j = i + 1; j < ne; j++) {   // crossing heights of edge pairs
            BKVec2f p = E[i].a, r = Sub(E[i].b, E[i].a), q = E[j].a, s = Sub(E[j].b, E[j].a);
            float den = r.x * s.y - r.y * s.x;
            if (den == 0) continue;
            float t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / den;
            float u = ((q.x - p.x) * r.y - (q.y - p.y) * r.x) / den;
            if (t > 0 && t < 1 && u > 0 && u < 1 && ny < maxY) Y[ny++] = p.y + r.y * t;
        }
    qsort(Y, ny, sizeof(float), CmpFloat);
    for (size_t k = 0; k + 1 < ny; k++) {
        float y0 = Y[k], y1 = Y[k + 1];
        if (!(y1 > y0)) continue;
        float ym = 0.5f * (y0 + y1);
        uint32_t nc = 0;
        for (uint32_t i = 0; i < ne; i++) {
            if (E[i].a.y <= ym && E[i].b.y > ym) {
                float dy = E[i].b.y - E[i].a.y;
                float sx = (E[i].b.x - E[i].a.x) / dy;
                cut[nc].x0 = E[i].a.x + (y0 - E[i].a.y) * sx;
                cut[nc].x1 = E[i].a.x + (y1 - E[i].a.y) * sx;
                cut[nc].xm = E[i].a.x + (ym - E[i].a.y) * sx;
                nc++;
            }
        }
        qsort(cut, nc, sizeof(Cut), CmpCut);
        for (uint32_t i = 0; i + 1 < nc; i += 2)
            SolidQuad(l, cmd, V2(cut[i].x0, y0), V2(cut[i + 1].x0, y0), V2(cut[i + 1].x1, y1), V2(cut[i].x1, y1),
                      color, color, color, color);
    }
    free(E); free(Y); free(cut);
}

void BKOverlayFillPolygon(BKOverlayList *l, const BKVec2f *points, const BKOverlayColor *colors,
                          uint32_t count, int rule, int smooth, BKOverlayColor color)
{
    if (!l) return;
    if (!points || count == 0) { l->error = l->error ? l->error : 2; return; }
    BKVec2f *P = (BKVec2f *)malloc(sizeof(BKVec2f) * count);
    BKOverlayColor *C = (BKOverlayColor *)malloc(sizeof(BKOverlayColor) * count);
    if (!P || !C) { free(P); free(C); l->error = 1; return; }
    uint32_t n = Clean(points, rule == BKOverlayFillFan ? colors : NULL, count, color, P, C);
    if (n >= 2 && P[0].x == P[n - 1].x && P[0].y == P[n - 1].y) n--;
    BKOverlayCommand *cmd = Command(l, BKOverlayModeSolid, -1, 0);
    if (n >= 3) {
        if (rule == BKOverlayFillEvenOdd) FillEvenOdd(l, cmd, P, n, color);
        else for (uint32_t i = 1; i + 1 < n; i++) SolidTri(l, cmd, P[0], P[i], P[i + 1], C[0], C[i], C[i + 1]);
        if (smooth) FillFringe(l, cmd, P, C, n);
    }
    free(P); free(C);
}

void BKOverlayFillTriangles(BKOverlayList *l, const BKVec2f *points, const BKOverlayColor *colors,
                            uint32_t count, BKOverlayColor color)
{
    if (!l) return;
    if (!points) { l->error = l->error ? l->error : 2; return; }
    BKOverlayCommand *cmd = Command(l, BKOverlayModeSolid, -1, 0);
    for (uint32_t i = 0; i + 2 < count; i += 3) {
        if (!Finite2(points[i]) || !Finite2(points[i + 1]) || !Finite2(points[i + 2])) continue;
        SolidTri(l, cmd, points[i], points[i + 1], points[i + 2],
                 colors ? colors[i] : color, colors ? colors[i + 1] : color, colors ? colors[i + 2] : color);
    }
}

// --- points -----------------------------------------------------------------------------------------
void BKOverlayPoints(BKOverlayList *l, const BKVec2f *points, const BKOverlayColor *colors,
                     uint32_t count, float size, int round, int smooth, BKOverlayColor color)
{
    if (!l) return;
    if (!points) { l->error = l->error ? l->error : 2; return; }
    if (!(size > 0)) size = 1;
    BKOverlayCommand *cmd = Command(l, BKOverlayModeSolid, -1, 0);
    float r = size * 0.5f;
    float core = smooth ? r - 0.5f : r, cover = 1.0f;
    if (core < 0) { cover = size; core = 0; }
    int segs = (int)ceilf(size * 1.5f); if (segs < 8) segs = 8; if (segs > 64) segs = 64;
    for (uint32_t i = 0; i < count; i++) {
        if (!Finite2(points[i])) continue;
        BKVec2f p = points[i];
        BKOverlayColor c = WithAlpha(colors ? colors[i] : color, cover), c0 = WithAlpha(c, 0);
        if (!round) {
            BKVec2f a = V2(p.x - core, p.y - core), b = V2(p.x + core, p.y - core), d = V2(p.x + core, p.y + core), e = V2(p.x - core, p.y + core);
            SolidQuad(l, cmd, a, b, d, e, c, c, c, c);
            if (smooth) {
                BKVec2f A = V2(a.x - 1, a.y - 1), B = V2(b.x + 1, b.y - 1), D = V2(d.x + 1, d.y + 1), Ee = V2(e.x - 1, e.y + 1);
                SolidQuad(l, cmd, a, A, B, b, c, c0, c0, c); SolidQuad(l, cmd, b, B, D, d, c, c0, c0, c);
                SolidQuad(l, cmd, d, D, Ee, e, c, c0, c0, c); SolidQuad(l, cmd, e, Ee, A, a, c, c0, c0, c);
            }
            continue;
        }
        for (int k = 0; k < segs; k++) {
            float a0 = 6.28318530718f * (float)k / (float)segs, a1 = 6.28318530718f * (float)(k + 1) / (float)segs;
            BKVec2f u0 = V2(cosf(a0), sinf(a0)), u1 = V2(cosf(a1), sinf(a1));
            BKVec2f q0 = Add(p, Mul(u0, core)), q1 = Add(p, Mul(u1, core));
            SolidTri(l, cmd, p, q0, q1, c, c, c);
            if (smooth) SolidQuad(l, cmd, q0, Add(q0, u0), Add(q1, u1), q1, c, c0, c0, c);
        }
    }
}

// --- images -----------------------------------------------------------------------------------------
int32_t BKOverlayAddImage(BKOverlayList *l, uint32_t width, uint32_t height, int32_t kind,
                          const uint8_t *pixels, size_t bytesPerRow)
{
    if (!l) return -1;
    if (!pixels || width == 0 || height == 0 || (kind != BKOverlayImageRGBA8 && kind != BKOverlayImageAlpha8)) {
        l->error = l->error ? l->error : 2; return -1;
    }
    size_t bpp = kind == BKOverlayImageRGBA8 ? 4 : 1, row = (size_t)width * bpp;
    if (bytesPerRow < row) { l->error = l->error ? l->error : 2; return -1; }
    if (!Grow((void **)&l->img, &l->imgCap, l->imgCount + 1, sizeof(BKOverlayImage))) { l->error = 1; return -1; }
    uint8_t *copy = (uint8_t *)malloc(row * height);
    if (!copy) { l->error = 1; return -1; }
    for (uint32_t y = 0; y < height; y++) memcpy(copy + row * y, pixels + bytesPerRow * y, row);
    BKOverlayImage *im = &l->img[l->imgCount];
    im->width = width; im->height = height; im->kind = kind; im->pixels = copy;
    return (int32_t)l->imgCount++;
}

void BKOverlayDrawImage(BKOverlayList *l, int32_t image, BKVec2f origin, BKVec2f uAxis, BKVec2f vAxis,
                        int linearFilter, BKOverlayColor color)
{
    if (!l) return;
    if (image < 0 || (uint32_t)image >= l->imgCount) { l->error = l->error ? l->error : 2; return; }
    const BKOverlayImage *im = &l->img[image];
    float w = (float)im->width, h = (float)im->height;
    int mode = im->kind == BKOverlayImageAlpha8 ? BKOverlayModeMask : BKOverlayModeImage;
    BKOverlayCommand *cmd = Command(l, mode, image, linearFilter ? 1 : 0);
    BKVec2f p00 = origin, p10 = Add(origin, Mul(uAxis, w)), p01 = Add(origin, Mul(vAxis, h)), p11 = Add(p10, Mul(vAxis, h));
    Tri(l, cmd, p00, p10, p11, color, color, color, V2(0, 0), V2(w, 0), V2(w, h));
    Tri(l, cmd, p00, p11, p01, color, color, color, V2(0, 0), V2(w, h), V2(0, h));
}

// --- CPU reference rasteriser -------------------------------------------------------------------------
static float Edge2(BKVec2f a, BKVec2f b, float px, float py) { return (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x); }
// Top-left rule (as GPUs fill, y down): a pixel centre exactly on an edge belongs to the triangle when
// the edge is a "top" edge (horizontal, triangle below it) or a "left" edge (triangle to its right).
// `c` is the triangle's third corner (tells on which side the triangle lies).
static int TopLeft(BKVec2f a, BKVec2f b, BKVec2f c)
{
    if (a.y == b.y) return c.y > a.y;
    float xe = a.x + (c.y - a.y) * (b.x - a.x) / (b.y - a.y);   // the edge's x at the third corner's height
    return c.x > xe;
}

static void Sample(const BKOverlayImage *im, float u, float v, int linear, float out[4])
{
    int bpp = im->kind == BKOverlayImageRGBA8 ? 4 : 1;
    int W = (int)im->width, H = (int)im->height;
    #define PIX(X, Y, K) ((float)im->pixels[((size_t)(Y) * W + (X)) * bpp + (K)] / 255.0f)
    if (!linear) {
        int x = (int)floorf(u), y = (int)floorf(v);
        x = x < 0 ? 0 : (x >= W ? W - 1 : x); y = y < 0 ? 0 : (y >= H ? H - 1 : y);
        for (int k = 0; k < 4; k++) out[k] = bpp == 4 ? PIX(x, y, k) : PIX(x, y, 0);
        return;
    }
    float fx = u - 0.5f, fy = v - 0.5f;
    int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
    float tx = fx - (float)x0, ty = fy - (float)y0;
    float acc[4] = { 0, 0, 0, 0 };
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++) {
            int x = x0 + i, y = y0 + j;
            x = x < 0 ? 0 : (x >= W ? W - 1 : x); y = y < 0 ? 0 : (y >= H ? H - 1 : y);
            float wgt = (i ? tx : 1 - tx) * (j ? ty : 1 - ty);
            for (int k = 0; k < 4; k++) acc[k] += wgt * (bpp == 4 ? PIX(x, y, k) : PIX(x, y, 0));
        }
    #undef PIX
    for (int k = 0; k < 4; k++) out[k] = acc[k];
}

void BKOverlayRasterize(const BKOverlayList *l, float *rgba, uint32_t width, uint32_t height)
{
    if (!l || !rgba) return;
    for (uint32_t ci = 0; ci < l->cCount; ci++) {
        const BKOverlayCommand *c = &l->c[ci];
        const BKOverlayImage *im = (c->image >= 0 && (uint32_t)c->image < l->imgCount) ? &l->img[c->image] : NULL;
        int x0c = 0, y0c = 0, x1c = (int)width, y1c = (int)height;
        if (c->hasClip) {
            x0c = c->clipX > 0 ? c->clipX : 0; y0c = c->clipY > 0 ? c->clipY : 0;
            x1c = c->clipX + c->clipW < (int)width ? c->clipX + c->clipW : (int)width;
            y1c = c->clipY + c->clipH < (int)height ? c->clipY + c->clipH : (int)height;
        }
        for (uint32_t t = c->first; t + 2 < c->first + c->count; t += 3) {
            const BKOverlayVertex *v = &l->v[t];
            BKVec2f a = V2(v[0].x, v[0].y), b = V2(v[1].x, v[1].y), d = V2(v[2].x, v[2].y);
            float area = Edge2(a, b, d.x, d.y);
            if (area == 0) continue;
            int ccw = area > 0;
            int bx0 = (int)floorf(fminf(a.x, fminf(b.x, d.x))), bx1 = (int)ceilf(fmaxf(a.x, fmaxf(b.x, d.x)));
            int by0 = (int)floorf(fminf(a.y, fminf(b.y, d.y))), by1 = (int)ceilf(fmaxf(a.y, fmaxf(b.y, d.y)));
            if (bx0 < x0c) bx0 = x0c; if (by0 < y0c) by0 = y0c; if (bx1 > x1c) bx1 = x1c; if (by1 > y1c) by1 = y1c;
            for (int y = by0; y < by1; y++)
                for (int x = bx0; x < bx1; x++) {
                    float px = (float)x + 0.5f, py = (float)y + 0.5f;
                    float w0 = Edge2(b, d, px, py), w1 = Edge2(d, a, px, py), w2 = Edge2(a, b, px, py);
                    if (!ccw) { w0 = -w0; w1 = -w1; w2 = -w2; }
                    if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                    if ((w0 == 0 && !TopLeft(b, d, a)) || (w1 == 0 && !TopLeft(d, a, b)) || (w2 == 0 && !TopLeft(a, b, d))) continue;
                    float s = fabsf(area);
                    float l0 = w0 / s, l1 = w1 / s, l2 = w2 / s;
                    float col[4] = { l0 * v[0].r + l1 * v[1].r + l2 * v[2].r, l0 * v[0].g + l1 * v[1].g + l2 * v[2].g,
                                     l0 * v[0].b + l1 * v[1].b + l2 * v[2].b, l0 * v[0].a + l1 * v[1].a + l2 * v[2].a };
                    if (im && c->mode != BKOverlayModeSolid) {
                        float tex[4];
                        Sample(im, l0 * v[0].u + l1 * v[1].u + l2 * v[2].u, l0 * v[0].v + l1 * v[1].v + l2 * v[2].v, c->linearFilter, tex);
                        if (c->mode == BKOverlayModeMask) col[3] *= tex[0];
                        else for (int k = 0; k < 4; k++) col[k] *= tex[k];
                    }
                    if (c->ignoreAlpha) col[3] = 1;
                    float *dst = rgba + ((size_t)y * width + (size_t)x) * 4;
                    float sa = col[3];
                    for (int k = 0; k < 3; k++) dst[k] = col[k] * sa + dst[k] * (1 - sa);
                    dst[3] = sa + dst[3] * (1 - sa);
                }
        }
    }
}
