// BorosKitRender: BKHeightBandCore - see include/BKHeightBandCore.h (definition, porting notes).
//
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-25, cpr-cutoff). VULKAN: safe to translate directly (pure C99, BKVec types).

#include "BKHeightBandCore.h"
#include <math.h>

BKVec3f BKHeightBandColumn(BKVec3d axis, BKVec3d origin, BKVec3d middle, BKVec3d rowStep, BKVec3d slabStep)
{
    double length = BKV3dLength(axis);
    if (!(length > 0) || !isfinite(length)) return BKV3f(0, 0, 0);
    BKVec3d a = BKV3dDiv(axis, length);
    return BKV3f((float)BKV3dDot(BKV3dSub(middle, origin), a), (float)BKV3dDot(rowStep, a), (float)BKV3dDot(slabStep, a));
}

void BKHeightBandNormalize(double *low, double *high, double minGap)
{
    if (low == NULL || high == NULL) return;
    if (!isfinite(*low)) *low = -20.0;
    if (!isfinite(*high)) *high = 20.0;
    if (*low > *high) { double t = *low; *low = *high; *high = t; }
    if (!(minGap >= 0)) minGap = 0;
    if (*high - *low < minGap) {   // widen around the middle
        double mid = 0.5 * (*low + *high);
        *low = mid - 0.5 * minGap;
        *high = mid + 0.5 * minGap;
    }
}

// What: signed distance of corner (x, y) from the line height == value (positive = above).
static double BKHBSide(BKHeightBandPictureFn fn, double value, double x, double y)
{
    return fn.c + fn.gx * x + fn.gy * y - value;
}

// What: the rectangle's corners in order (counter-clockwise in pixel space).
static void BKHBCorners(double w, double h, double xy[8])
{
    xy[0] = 0; xy[1] = 0;
    xy[2] = w; xy[3] = 0;
    xy[4] = w; xy[5] = h;
    xy[6] = 0; xy[7] = h;
}

uint32_t BKHeightBandClipRect(BKHeightBandPictureFn fn, double value, int above, double width, double height, double outXY[10])
{
    if (outXY == NULL || !(width > 0) || !(height > 0)) return 0;
    double corners[8];
    BKHBCorners(width, height, corners);
    double side[4];
    for (int i = 0; i < 4; i++) {
        side[i] = BKHBSide(fn, value, corners[2 * i], corners[2 * i + 1]);
        if (!above) side[i] = -side[i];   // keep the part below: flip the sign
    }
    // One pass of polygon clipping against the half-plane side > 0 (corners exactly on the line belong to
    // the band, so they are not counted as beyond it).
    uint32_t n = 0;
    for (int i = 0; i < 4; i++) {
        int j = (i + 1) % 4;
        double si = side[i], sj = side[j];
        if (si > 0 && n < 5) { outXY[2 * n] = corners[2 * i]; outXY[2 * n + 1] = corners[2 * i + 1]; n++; }
        if ((si > 0) != (sj > 0) && si != sj && n < 5) {
            double t = si / (si - sj);
            outXY[2 * n] = corners[2 * i] + t * (corners[2 * j] - corners[2 * i]);
            outXY[2 * n + 1] = corners[2 * i + 1] + t * (corners[2 * j + 1] - corners[2 * i + 1]);
            n++;
        }
    }
    return n >= 3 ? n : 0;
}

int BKHeightBandLineInRect(BKHeightBandPictureFn fn, double value, double width, double height, double out[4])
{
    if (out == NULL || !(width > 0) || !(height > 0)) return 0;
    if (fn.gx == 0 && fn.gy == 0) return 0;
    double corners[8];
    BKHBCorners(width, height, corners);
    double pts[8];
    int n = 0;
    for (int i = 0; i < 4 && n < 4; i++) {
        int j = (i + 1) % 4;
        double si = BKHBSide(fn, value, corners[2 * i], corners[2 * i + 1]);
        double sj = BKHBSide(fn, value, corners[2 * j], corners[2 * j + 1]);
        if (si == 0) {   // the line passes through a corner: take the corner once
            pts[2 * n] = corners[2 * i]; pts[2 * n + 1] = corners[2 * i + 1]; n++;
        } else if ((si > 0) != (sj > 0) && sj != 0) {
            double t = si / (si - sj);
            pts[2 * n] = corners[2 * i] + t * (corners[2 * j] - corners[2 * i]);
            pts[2 * n + 1] = corners[2 * i + 1] + t * (corners[2 * j + 1] - corners[2 * i + 1]);
            n++;
        }
    }
    if (n < 2) return 0;
    // The two farthest-apart points (a corner touch may add a duplicate).
    int a = 0, b = 1;
    double best = -1;
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++) {
            double dx = pts[2 * i] - pts[2 * j], dy = pts[2 * i + 1] - pts[2 * j + 1], d = dx * dx + dy * dy;
            if (d > best) { best = d; a = i; b = j; }
        }
    if (!(best > 0)) return 0;
    out[0] = pts[2 * a]; out[1] = pts[2 * a + 1];
    out[2] = pts[2 * b]; out[3] = pts[2 * b + 1];
    return 1;
}
