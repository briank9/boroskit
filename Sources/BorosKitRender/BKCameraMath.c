// BorosKitRender: camera maths (plain C). See include/BKCameraMath.h for what each
// function does and the porting notes.

#include "BKCameraMath.h"
#include <math.h>

// What: v scaled to length 1, or v unchanged when it is (almost) zero.
static BKVec3d BKSafeNormalize(BKVec3d v)
{
    double len = BKV3dLength(v);
    return len > 1e-12 ? BKV3dDiv(v, len) : v;
}

BKVec3d BKCameraRight(BKCameraFrame camera)
{
    return BKSafeNormalize(BKV3dCross(camera.direction, camera.up));
}

// What: half the height of the view in mm at `depth` in front of the camera.
// Orthographic: the parallel scale (the same at every depth). Perspective: the opening
// angle widens with the distance, tan(angle/2) * depth.
static double BKCameraHalfHeightAtDepth(BKCameraFrame camera, double depth)
{
    if (!camera.perspective) return camera.parallelScale;
    return tan(0.5 * camera.viewAngle * M_PI / 180.0) * depth;
}

double BKCameraMillimetresPerViewPoint(BKCameraFrame camera, double viewHeight, double depth)
{
    if (!(viewHeight > 0)) return 0;
    return 2.0 * BKCameraHalfHeightAtDepth(camera, depth) / viewHeight;
}

void BKCameraRayThroughViewPoint(BKCameraFrame camera, double viewWidth, double viewHeight,
                                 double x, double y, BKVec3d *origin, BKVec3d *direction)
{
    BKVec3d dir = BKSafeNormalize(camera.direction);
    BKVec3d up = BKSafeNormalize(camera.up);
    BKVec3d right = BKCameraRight(camera);
    // Offset of the point from the middle of the view, in view points, y UP.
    double ox = x - 0.5 * viewWidth;
    double oy = 0.5 * viewHeight - y;
    if (!camera.perspective) {
        // Every ray is parallel to the viewing direction; it starts on the plane through the
        // camera position, shifted sideways by the point's offset in millimetres.
        double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, 0);
        if (origin) *origin = BKV3dAddScaled(BKV3dAddScaled(camera.position, right, ox * mm), up, oy * mm);
        if (direction) *direction = dir;
    } else {
        // All rays leave the eye; at 1 mm in front of it the view is
        // 2 * tan(angle/2) mm high, so the point sits at that fraction of the way across.
        double mmAtOne = BKCameraMillimetresPerViewPoint(camera, viewHeight, 1.0);
        if (origin) *origin = camera.position;
        if (direction) *direction = BKSafeNormalize(BKV3dAddScaled(BKV3dAddScaled(dir, right, ox * mmAtOne), up, oy * mmAtOne));
    }
}

// What / why: see the header. Undoes BKCameraRayThroughViewPoint: the offset from the view's
// centre in mm (orthographic) or in mm at 1 mm in front of the eye (perspective, after dividing by
// the depth) is turned back into view points.
bool BKCameraProjectPoint(BKCameraFrame camera, double viewWidth, double viewHeight, BKVec3d p,
                          double *x, double *y, double *depth)
{
    BKVec3d dir = BKSafeNormalize(camera.direction);
    BKVec3d up = BKSafeNormalize(camera.up);
    BKVec3d right = BKCameraRight(camera);
    BKVec3d d = BKV3dSub(p, camera.position);
    double z = BKV3dDot(d, dir);
    double ox, oy;   // offset from the view's centre in view points, y UP
    if (!camera.perspective) {
        double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, 0);
        if (!(mm > 0)) return false;
        ox = BKV3dDot(d, right) / mm;
        oy = BKV3dDot(d, up) / mm;
    } else {
        if (!(z > 0)) return false;
        double mmAtOne = BKCameraMillimetresPerViewPoint(camera, viewHeight, 1.0);
        if (!(mmAtOne > 0)) return false;
        ox = BKV3dDot(d, right) / z / mmAtOne;
        oy = BKV3dDot(d, up) / z / mmAtOne;
    }
    if (x) *x = 0.5 * viewWidth + ox;
    if (y) *y = 0.5 * viewHeight - oy;
    if (depth) *depth = z;
    return true;
}

BKVec3d BKCameraWorldDeltaForViewDelta(BKCameraFrame camera, double viewHeight, double depth,
                                            double dx, double dy)
{
    double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, depth);
    BKVec3d up = BKSafeNormalize(camera.up);
    // dy is measured downwards on the screen; "up" in the patient is the opposite way.
    return BKV3dSub(BKV3dScale(BKCameraRight(camera), dx * mm), BKV3dScale(up, dy * mm));
}

bool BKCameraSlab(BKCameraFrame camera, double nearDistance, double farDistance,
                  BKVec3d *centrePoint, BKVec3d *normal, double *thickness)
{
    double len = BKV3dLength(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    BKVec3d dir = BKV3dDiv(camera.direction, len);
    // The slab is the stretch [near, far] along the viewing direction; its centre plane lies
    // halfway, and the plane faces along the view.
    if (centrePoint) *centrePoint = BKV3dAddScaled(camera.position, dir, 0.5 * (nearDistance + farDistance));
    if (normal) *normal = dir;
    if (thickness) *thickness = farDistance - nearDistance;
    return true;
}

bool BKCameraSlabPlanes(BKCameraFrame camera, double nearDistance, double farDistance, float out[8])
{
    double len = BKV3dLength(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    BKVec3d dir = BKV3dDiv(camera.direction, len);
    BKVec3d nearPoint = BKV3dAddScaled(camera.position, dir, nearDistance);
    BKVec3d farPoint = BKV3dAddScaled(camera.position, dir, farDistance);
    // Near plane: cut what lies towards the viewer, i.e. on the side of -dir.
    // Rule "cut when dot(n, x) + w > 0" with n = -dir and w = -dot(n, nearPoint).
    BKVec3d n0 = BKV3dNeg(dir);
    out[0] = (float)n0.x; out[1] = (float)n0.y; out[2] = (float)n0.z;
    out[3] = (float)(-BKV3dDot(n0, nearPoint));
    // Far plane: cut what lies beyond it, on the side of +dir.
    out[4] = (float)dir.x; out[5] = (float)dir.y; out[6] = (float)dir.z;
    out[7] = (float)(-BKV3dDot(dir, farPoint));
    return true;
}

bool BKCameraSlabContainsPoint(BKCameraFrame camera, double nearDistance, double farDistance, BKVec3d p)
{
    double len = BKV3dLength(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    // Distance of p in front of the camera, measured along the viewing direction.
    double d = BKV3dDot(BKV3dSub(p, camera.position), BKV3dDiv(camera.direction, len));
    return d >= nearDistance && d <= farDistance;
}

BKVec3d BKRotateVectorAroundAxis(BKVec3d v, BKVec3d axis, double radians)
{
    // Rodrigues' rotation formula: v cos + (k x v) sin + k (k . v)(1 - cos), k = unit axis.
    BKVec3d k = BKSafeNormalize(axis);
    double c = cos(radians), s = sin(radians);
    return BKV3dAdd(BKV3dAdd(BKV3dScale(v, c), BKV3dScale(BKV3dCross(k, v), s)), BKV3dScale(k, BKV3dDot(k, v) * (1.0 - c)));
}

void BKCameraYawPitchAboutPivot(BKCameraFrame *camera, BKVec3d *focalPoint, BKVec3d pivot,
                                double yawDegrees, double pitchDegrees)
{
    if (camera == NULL) return;
    double toRadians = M_PI / 180.0;
    BKVec3d dir = BKSafeNormalize(camera->direction);
    BKVec3d up = BKSafeNormalize(camera->up);

    // Step 1 - yaw: turn everything around the up axis through the pivot.
    // The up vector is the axis itself, so it does not change.
    double yaw = yawDegrees * toRadians;
    camera->position = BKV3dAdd(pivot, BKRotateVectorAroundAxis(BKV3dSub(camera->position, pivot), up, yaw));
    if (focalPoint) *focalPoint = BKV3dAdd(pivot, BKRotateVectorAroundAxis(BKV3dSub(*focalPoint, pivot), up, yaw));
    dir = BKRotateVectorAroundAxis(dir, up, yaw);

    // Step 2 - pitch: turn around the right axis of the camera as it is after the yaw.
    BKVec3d right = BKSafeNormalize(BKV3dCross(dir, up));
    double pitch = pitchDegrees * toRadians;
    camera->position = BKV3dAdd(pivot, BKRotateVectorAroundAxis(BKV3dSub(camera->position, pivot), right, pitch));
    if (focalPoint) *focalPoint = BKV3dAdd(pivot, BKRotateVectorAroundAxis(BKV3dSub(*focalPoint, pivot), right, pitch));
    dir = BKRotateVectorAroundAxis(dir, right, pitch);
    up = BKRotateVectorAroundAxis(up, right, pitch);

    // Keep "up" exactly perpendicular to the viewing direction (removes rounding drift).
    up = BKSafeNormalize(BKV3dSub(up, BKV3dScale(dir, BKV3dDot(up, dir))));
    camera->direction = BKSafeNormalize(dir);
    camera->up = up;
}
