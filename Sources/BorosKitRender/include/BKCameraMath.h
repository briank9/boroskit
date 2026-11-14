// BorosKitRender: camera maths for the interactive 3D view (plain C, no GPU code).
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C with <simd/simd.h> vector types only; no Objective-C, no Metal, no VTK and no
//   Horos-derived (LGPL) types such as N3Vector. A Vulkan build can use it unchanged
//   (simd_double3 can be swapped for any 3-double struct with the same meaning).
// - Nothing here is sent to the GPU directly. The only GPU-facing output is
//   BKCameraSlabPlanes(), which writes plain float4 planes (x, y, z, w) - std430 friendly,
//   the same packing as BKClipPlanesPack() - so a Vulkan shader reads them the same way.
// - Written from the geometry (dot/cross products, Rodrigues rotation); no code was
//   copied from VTK or elsewhere.
//
// Plain language: these helpers answer "where in the patient is this point of the
// screen?", "how far did the mouse move, in millimetres?", "which slice of the patient
// does a thick-slab view show?" and "turn the camera around a chosen point".
//
// Units: patient millimetres. Screen positions: view points with the origin at the
// TOP-LEFT corner (x to the right, y down), as everywhere else in BorosKit.

#ifndef BK_CAMERA_MATH_H
#define BK_CAMERA_MATH_H

#include <simd/simd.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: everything the helpers need to know about a camera.
// position:   the eye (perspective) or the centre of the near plane of the view (orthographic).
//             For a VTK-style camera this is "focal point - direction * distance".
// direction:  unit viewing direction.  up: unit, perpendicular to direction.
// parallelScale: orthographic only - half the height of the view in mm.
// viewAngle:  perspective only - full VERTICAL opening angle in degrees.
typedef struct {
    simd_double3 position;
    simd_double3 direction;
    simd_double3 up;
    double parallelScale;
    double viewAngle;
    bool perspective;
} BKCameraFrame;

// What: the unit vector pointing to the right of the picture: direction x up.
simd_double3 BKCameraRight(BKCameraFrame camera);

// What: the ray through screen point (x, y) of a view of viewWidth x viewHeight points.
// Orthographic: the ray starts on the plane through camera.position (perpendicular to the
// view) and runs along the viewing direction. Perspective: it starts at the eye.
// Why: picking the cropping-box handles and the pivot of the thick-slab rotation.
void BKCameraRayThroughViewPoint(BKCameraFrame camera, double viewWidth, double viewHeight,
                                 double x, double y, simd_double3 *origin, simd_double3 *direction);

// What: where patient point p appears on a view of viewWidth x viewHeight points (origin top-left,
// y down) - the exact inverse of BKCameraRayThroughViewPoint. *depth (optional) = mm in front of
// camera.position along the viewing direction. Returns false (x, y untouched) when the point is
// at or behind the eye of a perspective camera (it can't appear on screen).
// Why (2026-11-14): selecting a 3D point by clicking near its ball needs the ball's screen
// position from the BorosKit camera (no VTK).
bool BKCameraProjectPoint(BKCameraFrame camera, double viewWidth, double viewHeight, simd_double3 p,
                          double *x, double *y, double *depth);

// What: millimetres per view point at `depth` mm in front of camera.position (the depth is
// ignored for an orthographic camera, where it is the same everywhere).
double BKCameraMillimetresPerViewPoint(BKCameraFrame camera, double viewHeight, double depth);

// What: the patient-space move matching a mouse move of (dx, dy) view points (y down), for
// an object lying `depth` mm in front of camera.position. The result is parallel to the
// screen. Why: dragging a cropping-box face/handle should follow the mouse.
simd_double3 BKCameraWorldDeltaForViewDelta(BKCameraFrame camera, double viewHeight, double depth,
                                            double dx, double dy);

// What: a "camera slab": only the part of the patient between nearDistance and farDistance
// mm in front of camera.position along the viewing direction is shown (the VR window's
// clipping-range slab: near 0, far = thickness). Returns the slab's centre plane
// (a point and the unit normal = viewing direction) and its thickness. Returns false
// (outputs untouched) if far <= near or the direction is not usable.
// Why: the slab follows the camera; recomputing it from the camera on every frame keeps it
// glued to the view while the user rotates or moves.
bool BKCameraSlab(BKCameraFrame camera, double nearDistance, double farDistance,
                  simd_double3 *centrePoint, simd_double3 *normal, double *thickness);

// What: the same slab as two clipping planes, packed for a GPU like BKClipPlanesPack: each
// (nx, ny, nz, w) with a unit normal, and a point x is CUT AWAY when nx*x+ny*y+nz*z+w > 0.
// out[0..3] = near plane (cuts what is in front of it, towards the viewer),
// out[4..7] = far plane (cuts what is behind it). Returns false if the slab is not usable.
bool BKCameraSlabPlanes(BKCameraFrame camera, double nearDistance, double farDistance, float out[8]);

// What: YES when point p lies inside the slab (between the two planes, inclusive).
// Why: CPU reference for tests and callers.
bool BKCameraSlabContainsPoint(BKCameraFrame camera, double nearDistance, double farDistance, simd_double3 p);

// What: turns a camera around `pivot`: first `yawDegrees` around the camera's up axis, then
// `pitchDegrees` around its (new) right axis, both axes passing through the pivot. The
// position and the focal point turn together (the distance between them is kept), and the
// up vector is made perpendicular to the new viewing direction afterwards.
// Sign convention (same as the classic 3D window): positive yaw turns the viewing direction
// towards the camera's LEFT, positive pitch turns it UP.
// Why: the thick-slab mode of the 3D window turns the slab around the point the user
// clicked on (instead of around the centre of the volume).
// focalPoint may be NULL when only position/direction/up matter.
void BKCameraYawPitchAboutPivot(BKCameraFrame *camera, simd_double3 *focalPoint, simd_double3 pivot,
                                double yawDegrees, double pitchDegrees);

// What: rotates vector v by `radians` around the unit axis `axis` (right-hand rule).
// Why: shared building block (also used by the cropping-box maths).
simd_double3 BKRotateVectorAroundAxis(simd_double3 v, simd_double3 axis, double radians);

#ifdef __cplusplus
}
#endif

#endif
