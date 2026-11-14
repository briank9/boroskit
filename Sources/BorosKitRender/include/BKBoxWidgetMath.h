// BorosKitRender: maths of the 3D window's cropping box (plain C, no GPU code).
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit vector types (BKVec.h; moved off Apple simd 2026-11-14); no Objective-C, no Metal, no VTK and no
//   Horos-derived (LGPL) types such as N3Vector/N3Plane. A Vulkan build uses it unchanged.
// - The only GPU-facing output is BKBoxClipPlanes(): 6 planes as plain float4 (x, y, z, w),
//   std430 friendly and identical to BKClipPlanesPack()'s packing.
// - Written from the geometry (an oriented box = centre + three perpendicular axes +
//   half sizes; ray/sphere and ray/box tests); no code was copied from VTK or elsewhere.
//
// Plain language: the cropping box is a (possibly turned) rectangular box around the part
// of the scan you want to keep. It has 7 round "handles": one in the middle of each of its
// 6 faces (drag one to move that face) and one at its centre (drag it to move the whole
// box). Dragging a face without a handle turns the box; dragging with the right button
// makes it bigger/smaller; with the middle button it moves. These functions find what is
// under the mouse and change the box; the app then shows the result.
//
// Units: patient millimetres (any consistent unit works).

#ifndef BK_BOX_WIDGET_MATH_H
#define BK_BOX_WIDGET_MATH_H

#include "BKVec.h"   // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The 6 faces, in the same order as the handles of VTK's vtkBoxWidget (so the app can
// convert directly): -X, +X, -Y, +Y, -Z, +Z of the box's own axes.
enum {
    BKBoxFaceMinusX = 0, BKBoxFacePlusX = 1,
    BKBoxFaceMinusY = 2, BKBoxFacePlusY = 3,
    BKBoxFaceMinusZ = 4, BKBoxFacePlusZ = 5,
    BKBoxHandleCentre = 6,     // the 7th handle, in the middle of the box
    BKBoxHandleCount = 7
};

// What: a rectangular box in any orientation.
// centre: middle of the box. axis[0..2]: unit vectors along its edges, perpendicular to
// each other. halfSize[k]: half the edge length along axis[k] (>= 0).
typedef struct {
    BKVec3d centre;
    BKVec3d axis[3];
    double halfSize[3];
} BKOrientedBox;

// What: an axis-aligned box from its corners (min, max).
BKOrientedBox BKBoxMakeAxisAligned(BKVec3d boxMin, BKVec3d boxMax);

// What: the box from its 6 face centres (order -X, +X, -Y, +Y, -Z, +Z) and its centre,
// i.e. exactly the 7 handle positions VTK's box widget keeps. Returns false if a pair of
// opposite faces coincides (no direction can be found).
bool BKBoxFromHandles(const BKVec3d faceCentres[6], BKVec3d centre, BKOrientedBox *out);

// What: position of handle `handle` (0..5 = face centres, 6 = box centre).
BKVec3d BKBoxHandlePosition(BKOrientedBox box, int handle);

// What: unit normal of `face` pointing OUT of the box.
BKVec3d BKBoxFaceNormal(BKOrientedBox box, int face);

// What: the 8 corners. Order: corner i uses -/+ along axis 0, 1, 2 following VTK's
// hexahedron numbering (0: ---, 1: +--, 2: ++-, 3: -+-, 4: --+, 5: +-+, 6: +++, 7: -++).
void BKBoxCorners(BKOrientedBox box, BKVec3d out[8]);

// What: length of the box's diagonal (corner to opposite corner).
double BKBoxDiagonal(BKOrientedBox box);

// What: the handle hit by a ray, or -1. A handle counts as hit when the ray passes within
// radius = radiusAtOrigin + radiusPerDistance * t of its centre, where t is the distance
// along the ray (so a handle drawn at a fixed size on screen is hit at that size: for an
// orthographic view use radiusPerDistance 0, for a perspective view radiusAtOrigin 0).
// The handle nearest to the ray's origin wins. *distance (optional) gets its t.
int BKBoxPickHandle(BKOrientedBox box, BKVec3d origin, BKVec3d direction,
                    double radiusAtOrigin, double radiusPerDistance, double *distance);

// What: the face through which a ray ENTERS the box, or -1 if it misses the box (or starts
// inside it and never enters). *distance (optional) gets the entry distance along the ray.
int BKBoxPickFace(BKOrientedBox box, BKVec3d origin, BKVec3d direction, double *distance);

// What: moves `face` along its own normal by the part of `motion` that points along that
// normal (the opposite face stays where it is). The box never gets thinner than
// 2 * minHalfSize. Why: dragging a face handle.
void BKBoxMoveFace(BKOrientedBox *box, int face, BKVec3d motion, double minHalfSize);

// What: moves the whole box by `motion`. Why: centre handle / middle button.
void BKBoxTranslate(BKOrientedBox *box, BKVec3d motion);

// What: grows (factor > 1) or shrinks the box around its centre; no edge gets shorter than
// 2 * minHalfSize. Why: right-button drag.
void BKBoxScale(BKOrientedBox *box, double factor, double minHalfSize);

// What: turns the box around its centre by `radians` around `axis` (right-hand rule).
void BKBoxRotate(BKOrientedBox *box, BKVec3d axis, double radians);

// What: the turn for a drag on a face: the axis lies in the screen, perpendicular to the
// mouse motion (motion x viewDirection), and a drag as long as the box's diagonal turns it
// once all the way round: angle = 2*pi * |motion| / diagonal (the feel of the classic
// window's box). Returns false when there is nothing to turn (no motion, or motion along
// the view).
bool BKBoxRotationForDrag(BKOrientedBox box, BKVec3d viewDirection, BKVec3d motion,
                          BKVec3d *axis, double *radians);

// What: the size factor for a right-button drag: 1 + |motion| / diagonal when the mouse moved
// up on the screen (upwards > 0), 1 - |motion| / diagonal when it moved down; never below 0.1.
double BKBoxScaleFactorForDrag(BKOrientedBox box, BKVec3d motion, double upwards);

// What: the affine map that carries box `from` onto box `to` (each axis of `from` onto the
// same axis of `to`, stretched by the ratio of the half sizes), as a 4x4 row-major matrix
// m (p' = m * p, last row 0 0 0 1). Returns false if `from` is flat along an axis.
// Why: VTK's box widget stores its box as a transform; the app composes this map with it.
bool BKBoxAffineMap(BKOrientedBox from, BKOrientedBox to, double m[16]);

// What: the 6 faces as GPU clip planes (cut OUTSIDE the box), packed like BKClipPlanesPack:
// (nx, ny, nz, w), cut where nx*x + ny*y + nz*z + w > 0. Order: -X, +X, -Y, +Y, -Z, +Z.
void BKBoxClipPlanes(BKOrientedBox box, float out[24]);

// What: YES when p is inside the box or on its surface (tolerance 1e-9 mm).
bool BKBoxContainsPoint(BKOrientedBox box, BKVec3d p);

#ifdef __cplusplus
}
#endif

#endif
