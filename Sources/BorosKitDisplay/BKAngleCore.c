// BorosKitDisplay: BKAngleCore - see BKAngleCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKAngleCore.h"
#include <math.h>

#define BK_ANGLE_PI 3.14159265358979323846   /* own constant: M_PI is not part of strict C99 */

static float Len2(BKVec2f v) { return sqrtf(v.x * v.x + v.y * v.y); }

uint32_t BKAngleArcPoints(BKVec2f vertex, BKVec2f towardA, BKVec2f towardB, float radius, float maxStep,
                          BKVec2f *out, uint32_t maxOut)
{
    if (!out || maxOut < 3 || !(radius > 0) || !isfinite(radius)) return 0;
    BKVec2f a = { towardA.x - vertex.x, towardA.y - vertex.y };
    BKVec2f b = { towardB.x - vertex.x, towardB.y - vertex.y };
    if (!(Len2(a) > 0) || !(Len2(b) > 0)) return 0;
    double angA = atan2((double)a.y, (double)a.x);
    double sweep = atan2((double)b.y, (double)b.x) - angA;   // signed turn from A to B
    while (sweep > BK_ANGLE_PI) sweep -= 2.0 * BK_ANGLE_PI;                 // the shorter way: -pi .. pi
    while (sweep < -BK_ANGLE_PI) sweep += 2.0 * BK_ANGLE_PI;
    double arcLength = fabs(sweep) * radius;
    double step = maxStep > 0 ? (double)maxStep : 2.0;
    uint32_t n = (uint32_t)ceil(arcLength / step) + 1;
    if (n < 3) n = 3;
    if (n > maxOut) n = maxOut;
    for (uint32_t i = 0; i < n; i++) {
        double t = angA + sweep * (double)i / (double)(n - 1);
        out[i].x = vertex.x + (float)(cos(t) * radius);
        out[i].y = vertex.y + (float)(sin(t) * radius);
    }
    return n;
}

float BKAngleArcRadius(float armA, float armB, float preferred)
{
    float shorter = armA < armB ? armA : armB;
    if (!(shorter > 0) || !(preferred > 0)) return 0;
    float limit = 0.4f * shorter;
    return preferred < limit ? preferred : limit;
}

int BKAngleLineCrossing(BKVec2f a1, BKVec2f a2, BKVec2f b1, BKVec2f b2, BKVec2f *cross)
{
    double rx = a2.x - a1.x, ry = a2.y - a1.y, sx = b2.x - b1.x, sy = b2.y - b1.y;
    double den = rx * sy - ry * sx;
    double scale = sqrt(rx * rx + ry * ry) * sqrt(sx * sx + sy * sy);
    if (!(scale > 0) || fabs(den) <= 1e-9 * scale) return 0;   // parallel (or a zero-length line)
    double t = ((b1.x - a1.x) * sy - (b1.y - a1.y) * sx) / den;
    if (cross) { cross->x = (float)(a1.x + rx * t); cross->y = (float)(a1.y + ry * t); }
    return 1;
}

int BKDynamicAngleCorner(BKVec2f a1, BKVec2f a2, BKVec2f b1, BKVec2f b2,
                         BKVec2f *corner, BKVec2f *towardA, BKVec2f *towardB)
{
    BKVec2f c;
    if (!BKAngleLineCrossing(a1, a2, b1, b2, &c)) return 0;
    // Each ray towards its segment's end that is farther from the corner (the segment's side of the line).
    BKVec2f fa = Len2((BKVec2f){ a1.x - c.x, a1.y - c.y }) > Len2((BKVec2f){ a2.x - c.x, a2.y - c.y }) ? a1 : a2;
    BKVec2f fb = Len2((BKVec2f){ b1.x - c.x, b1.y - c.y }) > Len2((BKVec2f){ b2.x - c.x, b2.y - c.y }) ? b1 : b2;
    BKVec2f da = { fa.x - c.x, fa.y - c.y }, db = { fb.x - c.x, fb.y - c.y };
    float la = Len2(da), lb = Len2(db);
    if (!(la > 0) || !(lb > 0)) return 0;
    da.x /= la; da.y /= la; db.x /= lb; db.y /= lb;
    if (da.x * db.x + da.y * db.y < 0) { db.x = -db.x; db.y = -db.y; }   // keep the acute angle
    if (corner) *corner = c;
    if (towardA) { towardA->x = c.x + da.x; towardA->y = c.y + da.y; }
    if (towardB) { towardB->x = c.x + db.x; towardB->y = c.y + db.y; }
    return 1;
}
