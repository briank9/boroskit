// BorosKitRender: picture geometry of an MPR / curved-MPR thick-slab view (plain C, no GPU code).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit's own vector types (BKVec.h) and <stdint.h>; no Objective-C, no Metal,
//   no VTK, no OpenGL, no Apple simd and no Horos-derived (LGPL) types. Compiles unchanged on
//   Windows/Linux (check: clang -std=c99 -pedantic -Werror -fno-modules, no Apple headers).
// - Nothing here goes to the GPU. The result feeds the slab renderer's camera (centre, view size,
//   slab plane) and the 2D image the app stores (size, origin, orientation, pixel spacing).
// - Written from the geometry of an orthographic camera (dot products onto the camera's right /
//   up / viewing axes). It deliberately reproduces the numbers the classic engine produced, so
//   that measurements, ROIs and cross-reference lines are unchanged when Metal draws: the image
//   grid is render-size / sample-distance pixels, a "2 pixel margin" around the projected scan
//   box, integer truncation of the grid position, and the classic placement of pixel (0,0)
//   (see BKSlabGeometryCompute). Those rules were recorded as observed behaviour (numbers in
//   Tests/BorosKitRenderTests/BKSlabGeometryCoreTests.m were produced by the classic engine);
//   no code was copied from VTK or elsewhere.
// - Two rules are evaluated in single precision on purpose, because the classic engine does so
//   and integer truncation follows them: the sample distance is a float, and the grid size is
//   (int)((float)renderSize / (float)sampleDistance). Everything else is double.
// - Deterministic: no state, no threads, no allocation.
//
// Plain language: an MPR view looks at the scan through a thin "window pane" (the slab). This
// file answers: how many pixels does the picture have, where in the patient is its top-left
// pixel, which way do its rows and columns run, and how many millimetres is one pixel - from the
// view's camera, its size on screen and the scan's box. Before 2026-11-14 Boros 6 asked VTK for
// these numbers, which needed an OpenGL context and a VTK render pass on a hidden 3D view.
//
// Units: patient millimetres (convert VTK-style world units by dividing by the view's
// "world units per mm" factor before calling).

#ifndef BK_SLAB_GEOMETRY_CORE_H
#define BK_SLAB_GEOMETRY_CORE_H

#include "BKVec.h"     // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: everything needed to place one slab picture.
typedef struct {
    // --- Camera (orthographic), patient mm ---
    BKVec3d position;          // front face of the slab (the camera position; the slab runs from
                               // here `slabThickness` mm along the viewing direction)
    BKVec3d focalPoint;        // only the direction position -> focalPoint is used
    BKVec3d viewUp;            // screen "up"; made perpendicular to the viewing direction here
    double parallelScale;      // half the height of the view, mm (> 0)
    double windowCenterX;      // shift of the view centre in half-view units (VTK-style window
    double windowCenterY;      //   centre, usually 0, 0)
    double slabThickness;      // mm (> 0)

    // --- The view on screen ---
    int32_t renderWidth;       // size of the render surface in pixels (> 0)
    int32_t renderHeight;
    double frameWidth;         // size of the view's frame as the window-centre conversion uses it
    double frameHeight;        //   (the classic view's frame size in points; equals render size
                               //   when there is no Retina scaling between them)
    double sampleDistance;     // render pixels per picture pixel (the view's level of detail, >= 0.01)

    // --- The scan's box ---
    BKVec3d volumeOrigin;      // patient mm of voxel index (0, 0, 0)
    BKVec3d volumeAxes[3];     // unit directions of increasing index i, j, k (row, column, slice)
    BKVec3d voxelSpacing;      // mm between voxel centres along i, j, k (> 0)
    int32_t indexMin[3];       // first and last voxel index (inclusive) of the box along i, j, k
    int32_t indexMax[3];       //   (Boros 6's classic 3D view uses i 0..w-1, j 0..h-1, k 1..n-2)
} BKSlabGeometryInput;

// What: the placed picture.
typedef struct {
    int32_t width, height;             // picture size in pixels
    int32_t gridWidth, gridHeight;     // the full picture grid that covers the whole view
    int32_t gridOriginX, gridOriginY;  // where the picture starts in that grid (from bottom-left)
    int32_t coversWholeView;           // 1 = picture = whole grid; 0 = only where the scan box
                                       //   projects (thick slab that contains the whole scan)
    double resolution;                 // mm per render pixel
    double pixelSpacing;               // mm per picture pixel (= resolution * sampleDistance)
    double sampleDistance;             // the sample distance actually used (float precision)
    double slabThickness;              // mm
    BKVec3d origin;                    // patient mm of picture pixel (0, 0), in the MIDDLE of the slab
    BKVec3d right;                     // unit direction of increasing column (screen right)
    BKVec3d down;                      // unit direction of increasing row (screen down)
    BKVec3d towardViewer;              // unit, = -viewDirection (points out of the screen)
    BKVec3d viewDirection;             // unit viewing direction (position -> focalPoint)
} BKSlabGeometry;

typedef enum {
    BKSlabGeometryOK = 0,
    BKSlabGeometryBadInput = 1,        // sizes/scale/thickness/spacing not positive, NaN, or the
                                       //   camera vectors are zero or parallel: nothing written
} BKSlabGeometryStatus;

// What: computes the picture geometry for `in` (see BKSlabGeometryInput / BKSlabGeometry).
// Rules (reproducing the classic engine):
//  1. right = normalize(viewDirection x viewUp), up = right x viewDirection, down = -up.
//  2. grid = (int)((float)render / (float)sampleDistance) in each direction.
//  3. The picture covers the whole grid when the camera position lies inside the scan box, or when
//     any box corner lies in front of 0.1 % or beyond 99.99 % of the slab depth. Otherwise the 8
//     box corners are projected to normalised view units; the running minimum starts at +1 and
//     the maximum at -1 (so the range always reaches the view's middle - a scan off to the side
//     still gets a sliver a few pixels wide, as in the classic engine); the range is widened by
//     2 grid pixels on each side, clipped to the grid, and size = (int)(max - min + 1),
//     start = (int)min.
//  4. resolution = 2 * parallelScale / renderHeight.
//  5. With the picture start (x1, y1) = (int)(start * sampleDistance) render pixels from the
//     bottom-left, x = x1 - renderWidth/2 + windowCenterX * frameWidth/2 and
//     y = y1 - renderHeight/2 - windowCenterY * frameHeight/2:
//     origin = position + right * (x * resolution) + down * (y * resolution)
//              + viewDirection * (slabThickness / 2).
//     (For the usual whole-grid picture this is exactly the top-left pixel of the view, in the
//     middle of the slab. For a partial picture the classic engine measured y from the bottom and
//     applied it downwards; kept so both engines agree on where every picture pixel is.)
BKSlabGeometryStatus BKSlabGeometryCompute(const BKSlabGeometryInput *in, BKSlabGeometry *out);

// What: mm per render pixel for a view `renderHeight` pixels high showing 2 * parallelScale mm
// (rule 4 above), or 0 for unusable input. Why: the MPR views' automatic level of detail needs it
// before the full geometry is computed.
double BKSlabGeometryResolution(double parallelScale, int32_t renderHeight);

// What: the classic 3x3 orientation array the app stores with a picture: [0..2] = right,
// [3..5] = down, [6..8] = towardViewer.
void BKSlabGeometryOrientation(const BKSlabGeometry *g, double out[9]);

#ifdef __cplusplus
}
#endif

#endif
