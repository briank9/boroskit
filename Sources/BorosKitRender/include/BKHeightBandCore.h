// BorosKitRender: BKHeightBandCore - the curved-MPR "height cut-off" (top / bottom height limits): which
// samples lie inside a band between two parallel planes, and where that band's edges fall in a picture.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Boros 6 (2026-11-25, cpr-cutoff). What: the user drags two horizontal limit lines on the panorex and the
// cross-sections; everything above the top line and below the bottom line is excluded - never sampled into
// the panorex or the cross-sections (also not into a thick-slab MIP / MinIP / mean / X-ray projection), so
// the skull or the neck does not leak into the picture. Why here: the band test is part of the picture
// definition, so it lives in the plain C core that the GPU kernel (BKCurvedReformat.mm) mirrors line by line
// and that a Vulkan port must reproduce.
//
// Definition. A band = an axis A (unit vector, patient mm), an origin O and two limits low <= high (mm):
//   height(P) = dot(P - O, A);   P is inside when low <= height(P) <= high.
// The curved-MPR columns sample P = middle + rowStep * ry + slabStep * rz (BKCurvedReformatCore.h), so a
// column's height is the affine function
//   height(ry, rz) = h0 + hRow * ry + hSlab * rz,
//   h0 = dot(middle - O, A), hRow = dot(rowStep, A), hSlab = dot(slabStep, A)       (BKHeightBandColumn)
// Those three numbers go into the w components of the column's BKReformatFrame (base.w, row.w, slab.w) and
// the limits into BKReformatParams (bandEnabled, bandLow, bandHigh, bandOutsideValue).
// Each picture kind picks its axis / origin (Boros glue, BorosCurvedMPRGenerator.m):
//   straightened panorex: per column A = the curve's normal there, O = the curve point (height from the curve);
//   stretched panorex:    A = the projection normal, O = the mid-height point (height from the mid plane);
//   cross-sections:       the curve point / normal of the section (straightened) or the stretched plane.
//
// Picture helpers: on a picture the height is an affine function of the pixel position,
//   height(px, py) = c + gx * px + gy * py                                    (BKHeightBandPictureFn)
// BKHeightBandLineInRect gives the segment where height == value inside the picture rectangle (the limit
// line the views draw), BKHeightBandClipRect the part of the rectangle beyond a limit (the area the views
// dim or that is black).
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 (<math.h>, BKVec.h types only - no Objective-C, Metal, Apple
//   simd or Horos LGPL types). The in-band test used per sample (BKHeightBandInside) is a two-comparison
//   inline function the kernel repeats verbatim; the GPU reads the column's height function from the frame
//   buffer's w components (std430 vec4, no layout change) and the limits from the 32-bit scalar parameter
//   block (BK_REFORMAT_PARAMS_FIELDS). Comparisons are inclusive on both ends in every backend.
// - The picture helpers are CPU-only (overlay geometry); a Vulkan host uses them unchanged.

#ifndef BK_HEIGHT_BAND_CORE_H
#define BK_HEIGHT_BAND_CORE_H

#include <stdint.h>
#include "BKVec.h"

#ifdef __cplusplus
extern "C" {
#endif

// What: a sample at `height` (mm) is inside the band [low, high] (both ends included).
// GPU kernels repeat exactly this expression.
static inline int BKHeightBandInside(float low, float high, float height)
{
    return height >= low && height <= high;
}

// What: a column's height function (x = h0, y = hRow, z = hSlab; see the definition above) for the band axis
// `axis` (need not be unit length - it is normalised here; a zero axis gives all zeros = height 0 everywhere)
// and origin `origin`, for a column whose middle sample is at `middle` and whose row / slab steps are
// `rowStep` / `slabStep` (all patient mm).
BKVec3f BKHeightBandColumn(BKVec3d axis, BKVec3d origin, BKVec3d middle, BKVec3d rowStep, BKVec3d slabStep);

// What: the height (mm) of sample (ry, rz) of a column with height function `fn` (as BKHeightBandColumn).
static inline float BKHeightBandColumnHeight(BKVec3f fn, float ry, float rz)
{
    return fn.x + fn.y * ry + fn.z * rz;
}

// What: puts limits in order (low <= high) and keeps them at least `minGap` mm apart (a band of zero height
// would black out the whole picture by accident); NaN / infinite limits become the defaults -20 / +20 mm.
void BKHeightBandNormalize(double *low, double *high, double minGap);

// What: the height on a picture as a function of the pixel position (pixels as the views use them: the
// first pixel covers 0..1, so its centre is 0.5).
typedef struct {
    double c, gx, gy;   // height(px, py) = c + gx * px + gy * py (mm)
} BKHeightBandPictureFn;

// What: the segment inside the rectangle [0, width] x [0, height] where the picture height equals `value`.
// out = { x0, y0, x1, y1 }. Returns 1 when the line crosses the rectangle (a segment of non-zero length),
// else 0 (the line lies outside the picture, or the picture's height does not change: gx = gy = 0).
int BKHeightBandLineInRect(BKHeightBandPictureFn fn, double value, double width, double height, double out[4]);

// What: the part of the rectangle [0, width] x [0, height] where the picture height is above `value`
// (above = 1) or below it (above = 0), as a convex polygon (corners in the rectangle's own order
// (0,0) (w,0) (w,h) (0,h), up to 5 corners) in outXY = { x0, y0, x1, y1, ... } (room for 10 numbers). Returns the corner count: 0 = no part
// of the picture is beyond the limit, 4 = the whole rectangle, 3..5 = a part.
uint32_t BKHeightBandClipRect(BKHeightBandPictureFn fn, double value, int above, double width, double height, double outXY[10]);

#ifdef __cplusplus
}
#endif

#endif
