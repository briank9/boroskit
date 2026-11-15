// BorosKitRender: the camera of an MPR / curved-MPR slab view, and the mouse tools that move it
// (plain C, no GPU code).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - Pure C99 with BorosKit's own vector types (BKVec.h) and <math.h>; no Objective-C, no Metal,
//   no VTK, no OpenGL, no Apple simd and no Horos-derived (LGPL) types. Compiles unchanged on
//   Windows/Linux (check: clang -std=c99 -pedantic -Werror -fno-modules, no Apple headers).
// - Nothing here goes to the GPU. The camera feeds BKSlabGeometryCompute (picture placement) and
//   the slab renderer.
// - Written from the geometry of an orthographic camera (rotations about axes, dot/cross
//   products). It deliberately reproduces the numbers the classic engine produced for the same
//   mouse moves, so a plane, a measurement or a saved camera is the same whichever engine moved
//   it. Those rules were recorded as observed behaviour (the expected numbers in
//   Tests/BorosKitRenderTests/BKSlabCameraCoreTests.m were printed by the classic engine for the
//   same inputs); no code was copied from VTK or elsewhere. Rules that look odd but are kept on
//   purpose are marked "classic rule" below.
// - Deterministic: no state, no threads, no allocation. All functions accept NULL and bad
//   numbers and then change nothing.
//
// Plain language: each MPR view looks at the scan through a thin "window pane" (the slab). The
// camera says where the pane is (position), which way it faces (towards the focal point), which
// way is "up" on screen, and how much of the patient fits in the view (parallel scale). The
// mouse tools turn, slide and zoom that camera. Before 2026-11-15 Boros 6 kept this camera inside
// VTK (a hidden 3D view shared by the three MPR views) and let VTK's mouse code move it.
//
// Units: whatever units the caller uses for positions (Boros 6 passes its "world units", the same
// numbers its Camera objects hold - mm times the view's factor). Angles in degrees. Screen
// positions in render pixels with the origin at the BOTTOM-LEFT (y up), as the classic code
// passed them.

#ifndef BK_SLAB_CAMERA_CORE_H
#define BK_SLAB_CAMERA_CORE_H

#include "BKVec.h"     // BorosKit neutral vectors (no Apple simd: VULKAN-PORT-PLAN rule 1)
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: one slab view camera (orthographic).
typedef struct {
    BKVec3d position;          // the eye = front face of the slab
    BKVec3d focalPoint;        // a point ahead of the eye; only the direction to it matters for
                               //   the picture, its distance is kept for saved cameras
    BKVec3d viewUp;            // screen "up"; unit length, NOT necessarily perpendicular to the
                               //   viewing direction until BKSlabCameraOrthogonalizeUp (classic
                               //   behaviour: a stored "up" is only normalised)
    double parallelScale;      // half the height of the view (> 0)
    double windowCenterX;      // shift of the view centre in half-view units (usually 0, 0)
    double windowCenterY;
    double viewAngle;          // kept for saved cameras only (perspective angle, degrees)
    double eyeAngle;           // kept for saved cameras only
} BKSlabCamera;

// What: the axis-aligned box of the scan, the region the eye must stay inside while scrolling.
typedef struct {
    BKVec3d min;
    BKVec3d max;
} BKSlabCameraBox;

typedef enum {
    BKSlabCameraOK = 0,
    BKSlabCameraBadInput = 1,  // NULL, NaN/infinite numbers, eye on the focal point, zero "up",
                               //   or a non-positive size: nothing was changed
    BKSlabCameraRefused = 2,   // a move the classic code refuses (the eye would leave the scan
                               //   box): nothing was moved (see the function)
} BKSlabCameraStatus;

// What: the unit viewing direction (eye -> focal point), or (0, 0, 0) for a degenerate camera.
BKVec3d BKSlabCameraDirection(const BKSlabCamera *camera);

// What: unit "right" and "up" on screen, both perpendicular to the viewing direction:
// right = normalize(direction x viewUp), up = right x direction. Returns 0 (outputs untouched)
// for a degenerate camera.
int BKSlabCameraAxes(const BKSlabCamera *camera, BKVec3d *right, BKVec3d *up);

// What: stores `in` as the slab camera, the way the classic "write the camera, then read it back"
// round trip changed it: "up" is normalised (not straightened), and when `focalDistance` > 0 the
// focal point is moved to `focalDistance` ahead of the eye along the viewing direction (Boros 6
// uses 40 world units in slab mode). Everything else is copied.
BKSlabCameraStatus BKSlabCameraStore(const BKSlabCamera *in, double focalDistance, BKSlabCamera *out);

// What: makes "up" exactly perpendicular to the viewing direction (keeps it pointing the same
// side). Every classic read of the camera did this first.
BKSlabCameraStatus BKSlabCameraOrthogonalizeUp(BKSlabCamera *camera);

// What: the 9 numbers of the classic -getCosMatrix: (single precision, as the classic code):
// [0..2] = screen right, [3..5] = screen down (= -viewUp, normalised but not straightened),
// [6..8] = viewing direction. Returns 0 (all zero) for a degenerate camera.
int BKSlabCameraCosines(const BKSlabCamera *camera, float out[9]);

// What: the camera's roll in degrees, as the classic code stored it in Camera.rollAngle.
// Classic rule: the angle that remains after turning the view's back-facing normal onto +z by a
// turn about the y axis and then the x axis (each skipped when its axis is within 0.001 of the
// normal), measured from +y towards +x; 0 when "up" ends up within 0.001 of the z axis.
double BKSlabCameraRollDegrees(const BKSlabCamera *camera);

// What: the rotate tool ("spin"): turns "up" around the viewing direction by the angle between
// the previous and the current mouse position as seen from `centre` (all in render pixels, y up),
// then straightens "up". The picture follows the mouse.
BKSlabCameraStatus BKSlabCameraSpin(BKSlabCamera *camera, double centreX, double centreY,
                                    double lastX, double lastY, double x, double y);

// What: the move tool ("pan"): the picture follows the mouse from (lastX, lastY) to (x, y)
// (render pixels, y up): eye and focal point move by -(dx * right + dy * up) * 2 * parallelScale /
// renderHeight. "up" is not straightened (classic).
BKSlabCameraStatus BKSlabCameraPan(BKSlabCamera *camera, int32_t renderHeight,
                                   double lastX, double lastY, double x, double y);

// What: the zoom tool / right-drag: parallelScale /= 1.1 ^ (10 * dy / centreY), with dy = y - lastY
// in render pixels (y up: dragging up zooms in) and centreY = half the render height.
BKSlabCameraStatus BKSlabCameraZoom(BKSlabCamera *camera, double centreY, double lastY, double y);

// What: the wheel / drag-scroll: moves eye and focal point `distance` along the viewing direction
// (the single-precision direction of BKSlabCameraCosines, classic), keeping the eye-to-focal
// distance, then straightens "up". With `box` (not NULL) the move is REFUSED when the new eye is
// not strictly inside the box (classic: the slab stops at the scan's edge); "up" is straightened
// either way (classic). Returns BKSlabCameraRefused for a refused move.
BKSlabCameraStatus BKSlabCameraMoveAlongView(BKSlabCamera *camera, double distance, const BKSlabCameraBox *box);

// What: the 3D rotate / camera tool in slab mode: turns the camera around its EYE, first
// `yawDegrees` around its "up" (positive = viewing direction turns to the LEFT), then
// `pitchDegrees` around its new right axis (positive = turns UP), then straightens "up".
// Boros 6 passes yaw = -dx / 5 and pitch = -dy / 5 for a mouse move of (dx, dy) points.
BKSlabCameraStatus BKSlabCameraYawPitch(BKSlabCamera *camera, double yawDegrees, double pitchDegrees);

// What: the classic -setWindowCenter: (arrow keys, move-centre drag, Alt + 3D rotate pivot): sets
// the window centre so that the view centre lies at frame point (pointX, pointY) and moves the
// camera so the picture stays where it was. frame* = the view frame size the classic code used to
// convert to half-view units; render* = the render surface in pixels (they differ with Retina
// scaling, in which case the classic code moved the picture by the difference - kept).
// Classic rule: the camera moves by 1/10000 of the world offset of a screen point 10000 times
// further out than the centre change (so the picture keeps its place up to that 1/10000 part).
// Nothing changes when the window centre is already there.
BKSlabCameraStatus BKSlabCameraSetWindowCenter(BKSlabCamera *camera, double pointX, double pointY,
                                               double frameWidth, double frameHeight,
                                               int32_t renderWidth, int32_t renderHeight);

// What: the classic -windowCenter getter: the view centre's offset in frame points,
// (-windowCenterX * frameWidth / 2, windowCenterY * frameHeight / 2).
void BKSlabCameraGetWindowCenterPoint(const BKSlabCamera *camera, double frameWidth, double frameHeight,
                                      double *x, double *y);

// What: the axis-aligned box of a scan whose voxel (i, j, k) sits at
// scale * (origin + i * spacing.x * axes[0] + j * spacing.y * axes[1] + k * spacing.z * axes[2]),
// for i, j, k from indexMin to indexMax (inclusive): the box around its 8 corners. `scale` turns
// mm into the caller's units (Boros 6: world units per mm). Returns 0 for bad input.
int BKSlabCameraScanBox(BKVec3d origin, const BKVec3d axes[3], BKVec3d spacing,
                        const int32_t indexMin[3], const int32_t indexMax[3], double scale,
                        BKSlabCameraBox *box);

// What: 1 when p lies strictly inside the box (on a face counts as outside, classic).
int BKSlabCameraBoxContainsStrictly(const BKSlabCameraBox *box, BKVec3d p);

// What: the classic "Reset" of a slab view (-resetImage: with the slab on): focal point at the
// box centre, eye `eyeOffset` units towards +x from it (viewing towards -x, the left view),
// up = +z, parallelScale = half the box diagonal (0.5 for an empty box). Window centre and the
// saved-camera angles are left as they are. Boros 6 passes eyeOffset = 1 world unit.
BKSlabCameraStatus BKSlabCameraReset(BKSlabCamera *camera, const BKSlabCameraBox *box, double eyeOffset);

// What: the largest difference between two cameras (positions/focal points in the caller's units,
// up vectors, parallel scale and window centre all counted the same way). Why: the app's debug
// switch compares the classic engine's result with BorosKit's (see the "MISMATCH" log line).
double BKSlabCameraLargestDifference(const BKSlabCamera *a, const BKSlabCamera *b);

#ifdef __cplusplus
}
#endif

#endif
