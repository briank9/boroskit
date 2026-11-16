// BorosKitDisplay: BKROICore - ROI geometry, measurements, inside rule and statistics, plain C99.
// Overlay-engine plan step 5 (2026-11-16): the licence-free replacement of the ROI maths in Horos
// ROI.m / DCMPix.m. The OLD BEHAVIOUR WAS RECORDED (Tests/BorosKitDisplayTests/References, 18 ROIs of
// every kind on a synthetic image) and this file is written to give the same numbers; no old code was
// copied. Where a result depends on a float/double rounding detail, the comment says which rule is kept
// and why (the recorded value).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. Pure C99 (no Objective-C, Apple or LGPL types). Runs on the CPU
//   (ROI values are small jobs); a GPU version of the inside rule would use the same run rule.
// - Image pixel coordinates: x right, y down, pixel (i, j) covers [i, i+1) x [j, j+1).
// - Allocation: only the point/run lists returned by BKROICurve / BKROIInsideRuns (free with the
//   matching ...Free function).
//
// Plain language:
// - A ROI is a kind (length, rectangle, oval, polygon, ...) plus its points or its rectangle.
// - Its OUTLINE is the list of points that bound it (rectangle corners, 200 points round an oval, or the
//   user's points); its CURVE is the outline smoothed (polygons and pencil when smoothing is on).
// - The INSIDE pixels are found row by row from the curve (each pixel row: where the outline crosses it,
//   filled between pairs of crossings), and the statistics (mean, total, SD, min, max) come from them.

#ifndef BK_ROI_CORE_H
#define BK_ROI_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A point in image pixels (double, like the points ROIs store).
typedef struct { double x, y; } BKROIPoint;

// ROI kinds. The numbers are the ones Boros 6 stores in its ROI files (kept so files stay readable).
typedef enum {
    BKROIKindLength = 5,
    BKROIKindRect = 6,
    BKROIKindOval = 9,
    BKROIKindOpenPolygon = 10,
    BKROIKindClosedPolygon = 11,
    BKROIKindAngle = 12,
    BKROIKindText = 13,
    BKROIKindArrow = 14,
    BKROIKindPencil = 15,
    BKROIKindPoint = 19,
    BKROIKindAxis = 26,
    BKROIKindDynamicAngle = 27
} BKROIKind;

// One ROI. Rectangle and oval use the rect (rect: corner + size; oval: centre + half-width/half-height);
// a point uses the rect corner; the others use points.
typedef struct {
    int32_t kind;                 // BKROIKind
    const BKROIPoint *points;     // user's points (polygons, lines, angles)
    uint32_t count;
    double rectX, rectY, rectW, rectH;
    double spacingX, spacingY;    // pixel size in mm (0, 0 = unknown: lengths in pixels, no areas)
    int smooth;                   // 1: polygons and pencil are smoothed (the "spline" setting)
    int drawing;                  // 1: the ROI is being drawn (a closed kind is smoothed as open meanwhile)
} BKROIShape;

// A list of points made by this file (free with BKROIPointListFree).
typedef struct { BKROIPoint *points; uint32_t count; } BKROIPointList;
void BKROIPointListFree(BKROIPointList *list);

// What: the outline (see above): rect -> 4 corners (top-left, bottom-left, bottom-right, top-right);
// oval -> 200 points (angle steps of 1.8 degrees, starting on the right, the angle held as a float as
// recorded); point -> the rect corner; others -> a copy of the points.
BKROIPointList BKROIOutline(const BKROIShape *roi);

// What: the curve: the outline smoothed when roi->smooth and the kind is a polygon or pencil with at
// least 3 points; else the outline. `scale` = curve samples per pixel of outline length (Boros uses 5;
// above 5 counts as 5). Smoothing: a cubic curve through the points, parametrised by the distance
// between points (times scale), continuous in slope and bend, ending straight (no bend) one point
// beyond each end; for a closed kind the first point is repeated at the end and the neighbours wrap
// round (so the closed curve has no corner). Each piece between two points gives its start point and
// then one sample per whole step of `1/scale` pixel. Two equal neighbouring points -> no smoothing.
BKROIPointList BKROICurve(const BKROIShape *roi, double scale);

// What: area in pixels of a closed outline (the "shoelace" sum; float as recorded).
float BKROIPolygonAreaPixels(const BKROIPoint *pts, uint32_t n);

// What: the ROI area in cm2 (as shown in the ROI box): polygons, pencil, axis and dynamic angle from
// their curve; rectangle w x h; oval pi a b; others 0; 0 when the pixel size is unknown.
float BKROIAreaCm2(const BKROIShape *roi, const BKROIPointList *curve);

// What: distance from a to b in cm (pixel size known and inPixels 0) or in pixels.
float BKROILength(BKROIPoint a, BKROIPoint b, double spacingX, double spacingY, int inPixels);

// What: the angle in degrees at `vertex` between the arms to `a` and `b` (0..180), measured in mm
// (pixel size applied when known). 0 when the arm to `a` has zero length.
float BKROIAngle(BKROIPoint a, BKROIPoint vertex, BKROIPoint b, double spacingX, double spacingY);

// What: the ROI's centre point as Boros shows it: rect / oval / point -> the rect corner (centre for an
// oval); others -> the mean of the user's points.
BKROIPoint BKROICentroid(const BKROIShape *roi);

// ---- Inside pixels and statistics ----

// One row run of inside pixels: y, from x0 to x1 (both inside).
typedef struct { int32_t y, x0, x1; } BKROIRun;
typedef struct { BKROIRun *runs; uint32_t count; } BKROIRunList;
void BKROIRunListFree(BKROIRunList *list);

// What: the inside pixels of a closed curve on a width x height image, as row runs (top row first,
// left to right). Rule (recorded): the curve points are cut to whole pixels (towards zero); if any
// falls outside the image the outline is first cut to the image (x 0..width-1, y 0..height-1; new
// corners where it crosses, cut to whole pixels, computed in float as recorded); then each pixel row
// from the top of the outline down takes the x where each outline edge crosses it (edge from its top
// point: x_top + steps * dx / dy, rounded to the nearest whole pixel with halves away from x_top,
// each edge covering its rows from top to bottom except that a corner where the outline keeps going
// down (or up) counts once; flat edges are skipped), sorts them and fills from the 1st to the 2nd, 3rd
// to 4th, ... (an odd count repeats the last). The scan stops at the first row no edge reaches.
// Fewer than 3 points -> no runs.
BKROIRunList BKROIInsideRuns(const BKROIPoint *curve, uint32_t n, int32_t width, int32_t height);

// Statistics of the inside pixels.
typedef struct {
    uint32_t count;
    float mean, total, dev, min, max;   // dev: sample SD (count - 1), NaN for a single pixel as recorded
} BKROIStats;

// What: statistics of `runs` on a float image (row stride = width), summed in run order (as recorded:
// total and mean in double, the squared differences in float, min/max 0 when there are no pixels).
BKROIStats BKROIStatsOfRuns(const BKROIRunList *runs, const float *image, int32_t width, int32_t height);

// What: the one pixel of a point ROI: its value, or 0 when the point is outside the image (as recorded);
// *x / *y receive the whole-pixel position.
float BKROIPointValue(BKROIPoint p, const float *image, int32_t width, int32_t height, int32_t *x, int32_t *y);

// What: is image point (x, y) inside the ROI (the "click inside" test of the ROI tools)? Outside the
// curve's bounding box (whole pixels) -> no; rectangle -> yes; else the whole-pixel point (cut towards
// zero) tested against the curve with the even-odd rule (an edge counts when the point's row is at or
// below one end and above the other, and the point is left of the crossing).
int BKROIContainsPoint(int32_t kind, const BKROIPoint *curve, uint32_t n, double x, double y);

#ifdef __cplusplus
}
#endif

#endif
