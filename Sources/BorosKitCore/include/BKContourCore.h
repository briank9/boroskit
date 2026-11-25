// BorosKitCore: BKContourCore - outlines of the regions of a 2D picture at a given level ("marching squares"),
// joined into ordered lines. Plain C99.
// Boros 6 (2026-11-24, vtk-data): replaces VTK's vtkMarchingSquares / vtkContourFilter + vtkPolyDataConnectivityFilter
// in ITKSegmentation3D (brush ROI -> polygon, the brush outline used by the ROI volume and the 2D region growing
// result -> polygon ROIs).
//
// Original BorosKit code written for this project; contains no third-party code. Method (textbook marching squares):
// - pixel (x, y) is a sample at position (x, y); a pixel is INSIDE when its value >= level;
// - every square of 4 neighbouring pixels with inside and outside corners is crossed by the outline; the crossing
//   point on a square side lies where the straight line between the two pixel values reaches the level;
// - the pieces are given a direction (inside always on the same side), so each crossing point has exactly one
//   piece arriving and one leaving: following them gives ordered lines - closed loops, or open lines that end at
//   the picture border;
// - a square with two opposite inside corners (a "saddle") is joined through the middle when the average of its 4
//   values is >= level, otherwise the two inside corners stay apart;
// - repeated points (where a pixel value equals the level exactly) are dropped, so no piece has zero length;
// - order of the points: a loop starts at the crossing found first in scan order and runs the way the old
//   VTK-based code listed them (inside on the left when y points down the picture, i.e. anticlockwise on screen);
//   open lines run the same way round.
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly. CPU only, pure C99 (stdlib for the
// result arrays); deterministic: lines come out in scan order of their first piece (rows from y = 0, then x).
//
// Plain language: draws the border line around the painted (or segmented) pixels, in order, so it can become a
// polygon ROI.

#ifndef BK_CONTOUR_CORE_H
#define BK_CONTOUR_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double *xy;            // all points, 2 doubles (x, y) each, the lines one after another
    int *lineStart;        // lineCount + 1 entries: points of line k are lineStart[k] .. lineStart[k+1]-1
    int *lineClosed;       // 1 = closed loop (the last point joins the first; the first is not repeated)
    int pointCount, lineCount;
} BKContourLines;

// What: the outlines of `img` (width x height bytes, rowBytes apart) at `level`. out must be zeroed or freed
// before; free it with BKContourLinesFree. Returns 0, or -1 (bad arguments / out of memory: out left empty).
int BKContourExtractU8(const unsigned char *img, int width, int height, size_t rowBytes, double level,
                       BKContourLines *out);

// What: the number of pieces (segments) of line k: points for a closed loop, points - 1 for an open line.
int BKContourLineSegments(const BKContourLines *lines, int k);

// What: the line with the most pieces (the first one when several tie), or -1 when there is none.
int BKContourLargestLine(const BKContourLines *lines);

void BKContourLinesFree(BKContourLines *lines);

#ifdef __cplusplus
}
#endif

#endif
