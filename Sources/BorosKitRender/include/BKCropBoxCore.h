// BorosKitRender: the 3D window's cropping box as a native object - interaction and drawing
// geometry (plain C, no GPU code).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C with <simd/simd.h> vector types only; no Objective-C, Foundation, Metal, VTK or
//   Horos-derived (LGPL) types such as N3Vector/N3Plane. A Vulkan build uses it unchanged
//   (simd_double3 / simd_float3 can be swapped for any 3-component struct of the same meaning).
// - Nothing in this file is uploaded to the GPU as a struct. Planes come in and go out as plain
//   float4 (nx, ny, nz, w), cut where nx*x + ny*y + nz*z + w > 0 - the std430-friendly packing
//   of BKClipPlanesPack() / BKCameraSlabPlanes() / BKBoxClipPlanes(), so a Vulkan shader reads
//   them the same way. Drawing output is plain point lists (line segments, convex polygons) that
//   any backend turns into its own vertex buffers.
// - Flags inside structs are int32_t (never bool), so the structs keep the same layout in C,
//   C++, Metal Shading Language and GLSL should they ever be shared.
// - Written from the geometry (ray/box and ray/sphere tests, segment and convex-polygon clipping
//   against half-spaces); nothing was copied or translated from VTK or any other program.
//
// Plain language: the cropping box keeps the part of the scan inside it. BKBoxWidgetMath.h holds
// the box itself (BKOrientedBox: centre, three axes, half sizes) and the basic moves. This file
// adds what a complete native box needs:
//   * a mouse drag as a small state machine: "what did the click grab?" (a face handle, the
//     centre handle, a face, or nothing) and "how does the box change as the mouse moves?";
//     parts cut away by the thick-slab planes can't be grabbed (they are not shown either);
//   * what to draw: the 12 edges and the highlighted face, cut by the slab planes, and which of
//     the 7 handles are visible, with a handle size that stays constant on screen;
//   * converting the box to / from 6 planes the way the old VTK box widget stored them in the
//     3D window's saved states (so saved cameras keep working in both drawing paths);
//   * a sensible smallest box.
//
// Units: patient millimetres, unless a `scale` parameter says otherwise. Screen positions: view
// points, origin at the TOP-LEFT (x right, y down), as everywhere in BorosKit.

#ifndef BK_CROP_BOX_CORE_H
#define BK_CROP_BOX_CORE_H

#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>
#include "BKBoxWidgetMath.h"
#include "BKCameraMath.h"

#ifdef __cplusplus
extern "C" {
#endif

// What a drag does to the box (same meaning as the classic window's box widget).
enum {
    BKCropDragNone = 0,
    BKCropDragMoveFace = 1,    // left button on a face handle: that face moves along its normal
    BKCropDragTranslate = 2,   // centre handle, shift + left on the box, or middle button: box moves
    BKCropDragRotate = 3,      // left button on a face (not on a handle): the box turns
    BKCropDragScale = 4,       // right button on the box: grows (drag up) / shrinks (drag down)
};

// Which mouse button started the drag.
enum {
    BKCropButtonLeft = 0,
    BKCropButtonRight = 1,
    BKCropButtonMiddle = 2,
};

// What: one drag in progress, and what to highlight while it lasts.
// mode: BKCropDrag*. part: the handle (0..6) or, for a turn, the face (0..5) that was grabbed
// (-1 = none). highlightHandle: handle drawn in the "selected" colour (-1 = none).
// highlightFace: face filled in the "selected" colour (-1 = none). highlightOutline: 1 = edges in
// the "selected" colour (whole box moved / resized). depth: mm in front of camera.position of the
// grabbed point, so mouse motion turns into the right millimetres in a perspective view.
typedef struct {
    int32_t mode;
    int32_t part;
    int32_t highlightHandle;
    int32_t highlightFace;
    int32_t highlightOutline;
    int32_t padding;          // keeps `depth` 8-byte aligned the same way everywhere
    double depth;
} BKCropBoxDrag;

// Largest number of points a clipped face polygon can have: 4 corners + 1 per cutting plane.
#define BK_CROP_FACE_MAX_POINTS 16
// Largest number of cutting planes the drawing / picking helpers accept.
#define BK_CROP_MAX_CUT_PLANES 8

// What: YES when p is kept by every plane (planes packed as float4: cut where n.p + w > 0).
// count 0 keeps everything. Why: hides / ignores the parts of the box outside the thick slab.
bool BKCutPlanesKeepPoint(const float *planes, uint32_t count, simd_double3 p);

// What: radius in mm that a handle at `point` needs to look `radiusPoints` view points big.
// Why: handles keep the same size on screen whatever the zoom (like the classic window's).
double BKCropBoxScreenRadius(BKCameraFrame camera, double viewHeight, simd_double3 point, double radiusPoints);

// What: starts a drag at view point (x, yDown): finds the handle or face under the mouse and the
// kind of drag, as the classic box widget does:
//   right button on the box             -> resize;
//   middle button on the box            -> move;
//   left on a face handle               -> move that face;
//   left on the centre handle, or shift -> move the box;
//   left on a face (no handle)          -> turn.
// Handles are hit within pickRadiusPoints view points of their centre. Handles and face points cut
// away by `cutPlanes` (e.g. the thick slab) are ignored. Returns false (drag untouched) when the
// mouse is not on the box, so the click can move the camera instead.
bool BKCropBoxBeginDrag(BKOrientedBox box, BKCameraFrame camera, double viewWidth, double viewHeight,
                        double x, double yDown, int32_t button, bool shift, double pickRadiusPoints,
                        const float *cutPlanes, uint32_t cutPlaneCount, BKCropBoxDrag *drag);

// What: one mouse move of (dx, dyDown) view points during `drag`: changes `box` (face move, move,
// turn or resize). No edge gets shorter than minimumEdge mm. Returns true when the box changed.
bool BKCropBoxContinueDrag(BKOrientedBox *box, const BKCropBoxDrag *drag, BKCameraFrame camera,
                           double viewHeight, double dx, double dyDown, double minimumEdge);

// What: the 12 edges of the box, each cut by the planes (parts outside any plane removed), as
// pairs of points in `out` (room for 24 points). Returns the number of points written (2 per
// visible segment).
uint32_t BKCropBoxOutline(BKOrientedBox box, const float *cutPlanes, uint32_t cutPlaneCount, simd_float3 out[24]);

// What: face `face` (0..5) as a convex polygon cut by the planes, corners in order (room for
// BK_CROP_FACE_MAX_POINTS points). Returns the number of corners (0 when nothing is left, or for a
// bad face number). Why: the highlighted (yellow) face while it is dragged.
uint32_t BKCropBoxFacePolygon(BKOrientedBox box, int32_t face, const float *cutPlanes, uint32_t cutPlaneCount,
                              simd_float3 out[BK_CROP_FACE_MAX_POINTS]);

// What: the box from 6 planes given as origins / normals (3 doubles each, any normal direction),
// in the order -X, +X, -Y, +Y, -Z, +Z (opposite faces in pairs), multiplied by `scale` (to turn
// the caller's units into mm). Returns false (out untouched) for missing / invalid planes (zero or
// non-finite values, a pair that is not parallel, axes that are not perpendicular, a flat box).
// Why: restoring the box from the 3D window's saved camera state (which stores 6 planes).
bool BKBoxFromSixPlanes(const double origins[18], const double normals[18], double scale, BKOrientedBox *out);

// What: the 6 face planes the way the classic window's box widget stores them in saved states:
// origin = face centre, normal pointing INTO the box (the kept side), order -X, +X, -Y, +Y, -Z, +Z,
// origins multiplied by `scale` (mm -> the caller's units). Inverse of BKBoxFromSixPlanes.
void BKBoxKeptSidePlanes(BKOrientedBox box, double scale, double origins[18], double normals[18]);

// What: the smallest axis-aligned box that holds the (possibly turned) box.
void BKBoxAxisAlignedBounds(BKOrientedBox box, simd_double3 *boxMin, simd_double3 *boxMax);

// What: YES when the two boxes are the same within `tolerance` mm (centre, half sizes, and the
// face directions, where the axes may be listed in the same order only).
bool BKBoxNearlyEqual(BKOrientedBox a, BKOrientedBox b, double tolerance);

// What: the smallest edge length allowed while dragging: 2 mm, or two voxels of the scan when its
// voxels are bigger than 1 mm (largestVoxelSize = the biggest of the three voxel spacings, mm).
// Why: a thinner box shows nothing useful, its face handles would sit on top of each other and
// the opposite faces could no longer be told apart (before: 1 mm whatever the scan).
double BKCropBoxMinimumEdge(double largestVoxelSize);

#ifdef __cplusplus
}
#endif

#endif
