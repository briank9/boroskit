// BorosKitRender: camera maths (plain C). See include/BKCameraMath.h for what each
// function does and the porting notes.

#include "BKCameraMath.h"
#include <math.h>

// What: v scaled to length 1, or v unchanged when it is (almost) zero.
static simd_double3 BKSafeNormalize(simd_double3 v)
{
    double len = simd_length(v);
    return len > 1e-12 ? v / len : v;
}

simd_double3 BKCameraRight(BKCameraFrame camera)
{
    return BKSafeNormalize(simd_cross(camera.direction, camera.up));
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
                                 double x, double y, simd_double3 *origin, simd_double3 *direction)
{
    simd_double3 dir = BKSafeNormalize(camera.direction);
    simd_double3 up = BKSafeNormalize(camera.up);
    simd_double3 right = BKCameraRight(camera);
    // Offset of the point from the middle of the view, in view points, y UP.
    double ox = x - 0.5 * viewWidth;
    double oy = 0.5 * viewHeight - y;
    if (!camera.perspective) {
        // Every ray is parallel to the viewing direction; it starts on the plane through the
        // camera position, shifted sideways by the point's offset in millimetres.
        double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, 0);
        if (origin) *origin = camera.position + right * (ox * mm) + up * (oy * mm);
        if (direction) *direction = dir;
    } else {
        // All rays leave the eye; at 1 mm in front of it the view is
        // 2 * tan(angle/2) mm high, so the point sits at that fraction of the way across.
        double mmAtOne = BKCameraMillimetresPerViewPoint(camera, viewHeight, 1.0);
        if (origin) *origin = camera.position;
        if (direction) *direction = BKSafeNormalize(dir + right * (ox * mmAtOne) + up * (oy * mmAtOne));
    }
}

// What / why: see the header. Undoes BKCameraRayThroughViewPoint: the offset from the view's
// centre in mm (orthographic) or in mm at 1 mm in front of the eye (perspective, after dividing by
// the depth) is turned back into view points.
bool BKCameraProjectPoint(BKCameraFrame camera, double viewWidth, double viewHeight, simd_double3 p,
                          double *x, double *y, double *depth)
{
    simd_double3 dir = BKSafeNormalize(camera.direction);
    simd_double3 up = BKSafeNormalize(camera.up);
    simd_double3 right = BKCameraRight(camera);
    simd_double3 d = p - camera.position;
    double z = simd_dot(d, dir);
    double ox, oy;   // offset from the view's centre in view points, y UP
    if (!camera.perspective) {
        double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, 0);
        if (!(mm > 0)) return false;
        ox = simd_dot(d, right) / mm;
        oy = simd_dot(d, up) / mm;
    } else {
        if (!(z > 0)) return false;
        double mmAtOne = BKCameraMillimetresPerViewPoint(camera, viewHeight, 1.0);
        if (!(mmAtOne > 0)) return false;
        ox = simd_dot(d, right) / z / mmAtOne;
        oy = simd_dot(d, up) / z / mmAtOne;
    }
    if (x) *x = 0.5 * viewWidth + ox;
    if (y) *y = 0.5 * viewHeight - oy;
    if (depth) *depth = z;
    return true;
}

simd_double3 BKCameraWorldDeltaForViewDelta(BKCameraFrame camera, double viewHeight, double depth,
                                            double dx, double dy)
{
    double mm = BKCameraMillimetresPerViewPoint(camera, viewHeight, depth);
    simd_double3 up = BKSafeNormalize(camera.up);
    // dy is measured downwards on the screen; "up" in the patient is the opposite way.
    return BKCameraRight(camera) * (dx * mm) - up * (dy * mm);
}

bool BKCameraSlab(BKCameraFrame camera, double nearDistance, double farDistance,
                  simd_double3 *centrePoint, simd_double3 *normal, double *thickness)
{
    double len = simd_length(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    simd_double3 dir = camera.direction / len;
    // The slab is the stretch [near, far] along the viewing direction; its centre plane lies
    // halfway, and the plane faces along the view.
    if (centrePoint) *centrePoint = camera.position + dir * (0.5 * (nearDistance + farDistance));
    if (normal) *normal = dir;
    if (thickness) *thickness = farDistance - nearDistance;
    return true;
}

bool BKCameraSlabPlanes(BKCameraFrame camera, double nearDistance, double farDistance, float out[8])
{
    double len = simd_length(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    simd_double3 dir = camera.direction / len;
    simd_double3 nearPoint = camera.position + dir * nearDistance;
    simd_double3 farPoint = camera.position + dir * farDistance;
    // Near plane: cut what lies towards the viewer, i.e. on the side of -dir.
    // Rule "cut when dot(n, x) + w > 0" with n = -dir and w = -dot(n, nearPoint).
    simd_double3 n0 = -dir;
    out[0] = (float)n0.x; out[1] = (float)n0.y; out[2] = (float)n0.z;
    out[3] = (float)(-simd_dot(n0, nearPoint));
    // Far plane: cut what lies beyond it, on the side of +dir.
    out[4] = (float)dir.x; out[5] = (float)dir.y; out[6] = (float)dir.z;
    out[7] = (float)(-simd_dot(dir, farPoint));
    return true;
}

bool BKCameraSlabContainsPoint(BKCameraFrame camera, double nearDistance, double farDistance, simd_double3 p)
{
    double len = simd_length(camera.direction);
    if (!(farDistance > nearDistance) || !(len > 1e-12)) return false;
    // Distance of p in front of the camera, measured along the viewing direction.
    double d = simd_dot(p - camera.position, camera.direction / len);
    return d >= nearDistance && d <= farDistance;
}

simd_double3 BKRotateVectorAroundAxis(simd_double3 v, simd_double3 axis, double radians)
{
    // Rodrigues' rotation formula: v cos + (k x v) sin + k (k . v)(1 - cos), k = unit axis.
    simd_double3 k = BKSafeNormalize(axis);
    double c = cos(radians), s = sin(radians);
    return v * c + simd_cross(k, v) * s + k * (simd_dot(k, v) * (1.0 - c));
}

void BKCameraYawPitchAboutPivot(BKCameraFrame *camera, simd_double3 *focalPoint, simd_double3 pivot,
                                double yawDegrees, double pitchDegrees)
{
    if (camera == NULL) return;
    double toRadians = M_PI / 180.0;
    simd_double3 dir = BKSafeNormalize(camera->direction);
    simd_double3 up = BKSafeNormalize(camera->up);

    // Step 1 - yaw: turn everything around the up axis through the pivot.
    // The up vector is the axis itself, so it does not change.
    double yaw = yawDegrees * toRadians;
    camera->position = pivot + BKRotateVectorAroundAxis(camera->position - pivot, up, yaw);
    if (focalPoint) *focalPoint = pivot + BKRotateVectorAroundAxis(*focalPoint - pivot, up, yaw);
    dir = BKRotateVectorAroundAxis(dir, up, yaw);

    // Step 2 - pitch: turn around the right axis of the camera as it is after the yaw.
    simd_double3 right = BKSafeNormalize(simd_cross(dir, up));
    double pitch = pitchDegrees * toRadians;
    camera->position = pivot + BKRotateVectorAroundAxis(camera->position - pivot, right, pitch);
    if (focalPoint) *focalPoint = pivot + BKRotateVectorAroundAxis(*focalPoint - pivot, right, pitch);
    dir = BKRotateVectorAroundAxis(dir, right, pitch);
    up = BKRotateVectorAroundAxis(up, right, pitch);

    // Keep "up" exactly perpendicular to the viewing direction (removes rounding drift).
    up = BKSafeNormalize(up - dir * simd_dot(up, dir));
    camera->direction = BKSafeNormalize(dir);
    camera->up = up;
}
