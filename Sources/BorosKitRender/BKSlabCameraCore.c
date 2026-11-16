// BorosKitRender: the camera of an MPR / curved-MPR slab view and its mouse tools (plain C).
// See include/BKSlabCameraCore.h for what each function does, the rules and the porting notes.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabCameraCore.h"
#include <math.h>

#define BK_SLAB_PI 3.14159265358979323846

// What: is every component of v finite?
static int BKSCFinite3(BKVec3d v)
{
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

// What: is the camera made of usable numbers (eye not on the focal point, "up" not zero)?
static int BKSCUsable(const BKSlabCamera *c)
{
    if (c == NULL) return 0;
    if (!BKSCFinite3(c->position) || !BKSCFinite3(c->focalPoint) || !BKSCFinite3(c->viewUp)) return 0;
    if (!isfinite(c->parallelScale) || !isfinite(c->windowCenterX) || !isfinite(c->windowCenterY)) return 0;
    if (!(BKV3dLength(BKV3dSub(c->focalPoint, c->position)) > 1e-20)) return 0;
    if (!(BKV3dLength(c->viewUp) > 0)) return 0;
    return 1;
}

// What: rotates v by `degrees` around the unit `axis`, right-hand rule (Rodrigues' formula:
// v cos + (k x v) sin + k (k . v)(1 - cos)). Seen from the tip of the axis looking back, a
// positive angle turns counter-clockwise.
static BKVec3d BKSCRotate(BKVec3d v, BKVec3d axis, double degrees)
{
    double a = degrees * (BK_SLAB_PI / 180.0);
    double c = cos(a), s = sin(a);
    return BKV3dAdd(BKV3dAdd(BKV3dScale(v, c), BKV3dScale(BKV3dCross(axis, v), s)),
                    BKV3dScale(axis, BKV3dDot(axis, v) * (1.0 - c)));
}

BKVec3d BKSlabCameraDirection(const BKSlabCamera *camera)
{
    if (camera == NULL) return BKV3d(0, 0, 0);
    BKVec3d d = BKV3dSub(camera->focalPoint, camera->position);
    double length = BKV3dLength(d);
    if (!(length > 1e-20) || !isfinite(length)) return BKV3d(0, 0, 0);
    return BKV3dDiv(d, length);
}

int BKSlabCameraAxes(const BKSlabCamera *camera, BKVec3d *right, BKVec3d *up)
{
    if (!BKSCUsable(camera)) return 0;
    BKVec3d dir = BKSlabCameraDirection(camera);
    BKVec3d side = BKV3dCross(dir, camera->viewUp);
    double sideLength = BKV3dLength(side);
    if (!(sideLength > 1e-12)) return 0;   // "up" parallel to the viewing direction
    BKVec3d r = BKV3dDiv(side, sideLength);
    if (right) *right = r;
    if (up) *up = BKV3dCross(r, dir);      // unit: r and dir are unit and perpendicular
    return 1;
}

BKSlabCameraStatus BKSlabCameraStore(const BKSlabCamera *in, double focalDistance, BKSlabCamera *out)
{
    if (in == NULL || out == NULL || !isfinite(focalDistance)) return BKSlabCameraBadInput;
    // Usable apart from "up" (a zero "up" is allowed here: classic rule below).
    BKSlabCamera c = *in;
    if (BKV3dLength(c.viewUp) == 0 && BKSCFinite3(c.viewUp)) c.viewUp = BKV3d(0, 1, 0);
    if (!BKSCUsable(&c)) return BKSlabCameraBadInput;
    c.viewUp = BKV3dNormalize(c.viewUp);   // classic: normalised, not straightened
    if (focalDistance > 0)
        c.focalPoint = BKV3dAddScaled(c.position, BKSlabCameraDirection(in), focalDistance);
    *out = c;
    return BKSlabCameraOK;
}

BKSlabCameraStatus BKSlabCameraOrthogonalizeUp(BKSlabCamera *camera)
{
    BKVec3d up;
    if (!BKSlabCameraAxes(camera, NULL, &up)) return BKSlabCameraBadInput;
    camera->viewUp = up;
    return BKSlabCameraOK;
}

BKSlabCameraStatus BKSlabCameraReadBack(BKSlabCamera *camera)
{
    if (camera == NULL || !BKSCFinite3(camera->position) || !BKSCFinite3(camera->focalPoint) ||
        !BKSCFinite3(camera->viewUp) || !(BKV3dLength(BKV3dSub(camera->focalPoint, camera->position)) > 1e-20))
        return BKSlabCameraBadInput;
    if (BKV3dLength(camera->viewUp) > 0 && BKSlabCameraOrthogonalizeUp(camera) == BKSlabCameraOK)
        return BKSlabCameraOK;
    camera->viewUp = BKV3d(0, 0, 0);   // classic: no screen orientation -> "up" read back as zero
    return BKSlabCameraRefused;
}

int BKSlabCameraCosines(const BKSlabCamera *camera, float out[9])
{
    if (out == NULL) return 0;
    for (int i = 0; i < 9; i++) out[i] = 0;
    if (!BKSCUsable(camera)) return 0;

    // Single precision on purpose: the classic numbers were floats, and the scroll step uses them.
    // Screen down = -up, normalised (up is used as stored, not straightened).
    out[3] = (float)(camera->viewUp.x * -1.0);
    out[4] = (float)(camera->viewUp.y * -1.0);
    out[5] = (float)(camera->viewUp.z * -1.0);
    double length = sqrt(out[3] * out[3] + out[4] * out[4] + out[5] * out[5]);
    if (!(length != 0)) { for (int i = 0; i < 9; i++) out[i] = 0; return 0; }
    out[3] = (float)(out[3] / length); out[4] = (float)(out[4] / length); out[5] = (float)(out[5] / length);

    // Viewing direction.
    BKVec3d dir = BKSlabCameraDirection(camera);
    out[6] = (float)dir.x; out[7] = (float)dir.y; out[8] = (float)dir.z;
    length = sqrt(out[6] * out[6] + out[7] * out[7] + out[8] * out[8]);
    if (length != 0) { out[6] = (float)(out[6] / length); out[7] = (float)(out[7] / length); out[8] = (float)(out[8] / length); }

    // Screen right = direction x up = -(direction x down), normalised.
    out[0] = -(out[7] * out[5] - out[8] * out[4]);
    out[1] = -(out[8] * out[3] - out[6] * out[5]);
    out[2] = -(out[6] * out[4] - out[7] * out[3]);
    length = sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]);
    if (!(length != 0)) { for (int i = 0; i < 9; i++) out[i] = 0; return 0; }
    out[0] = (float)(out[0] / length); out[1] = (float)(out[1] / length); out[2] = (float)(out[2] / length);
    return 1;
}

double BKSlabCameraRollDegrees(const BKSlabCamera *camera)
{
    BKVec3d right, up;
    if (!BKSlabCameraAxes(camera, &right, &up)) return 0;
    BKVec3d n = BKV3dNeg(BKSlabCameraDirection(camera));   // the view's back-facing normal
    const double eps = 0.001;                              // classic tolerance

    // Turn about y that brings n into the y-z plane (skipped when n is almost along y).
    double h = sqrt(n.x * n.x + n.z * n.z);
    double cosY = 1.0, sinY = 0.0;
    if (h >= eps) { cosY = n.z / h; sinY = n.x / h; }
    // Then the turn about x that brings it onto +z.
    double sinX = n.y, cosX = (h >= eps) ? h : n.z;
    // "up" after undoing both turns; the roll is its angle from +y towards +x.
    double ux = up.x * cosY - up.z * sinY;
    double uy = -sinX * sinY * up.x + cosX * up.y - sinX * cosY * up.z;
    if (sqrt(ux * ux + uy * uy) < eps) return 0;
    return atan2(ux, uy) * (180.0 / BK_SLAB_PI);
}

BKSlabCameraStatus BKSlabCameraSpin(BKSlabCamera *camera, double centreX, double centreY,
                                    double lastX, double lastY, double x, double y)
{
    if (!BKSCUsable(camera) || !isfinite(centreX) || !isfinite(centreY) || !isfinite(lastX) ||
        !isfinite(lastY) || !isfinite(x) || !isfinite(y))
        return BKSlabCameraBadInput;
    double newAngle = atan2(y - centreY, x - centreX) * (180.0 / BK_SLAB_PI);
    double oldAngle = atan2(lastY - centreY, lastX - centreX) * (180.0 / BK_SLAB_PI);
    // "up" turns around the viewing direction by the mouse's turn (right-hand rule about the
    // direction = clockwise as the viewer sees it), so the picture turns WITH the mouse.
    BKSlabCamera c = *camera;
    c.viewUp = BKV3dNormalize(BKSCRotate(camera->viewUp, BKSlabCameraDirection(camera), newAngle - oldAngle));
    if (BKSlabCameraOrthogonalizeUp(&c) != BKSlabCameraOK) return BKSlabCameraBadInput;
    *camera = c;
    return BKSlabCameraOK;
}

BKSlabCameraStatus BKSlabCameraPan(BKSlabCamera *camera, int32_t renderHeight,
                                   double lastX, double lastY, double x, double y)
{
    BKVec3d right, up;
    if (renderHeight <= 0 || !BKSlabCameraAxes(camera, &right, &up) || !(camera->parallelScale > 0) ||
        !isfinite(lastX) || !isfinite(lastY) || !isfinite(x) || !isfinite(y))
        return BKSlabCameraBadInput;
    double perPixel = 2.0 * camera->parallelScale / (double)renderHeight;
    BKVec3d move = BKV3dAdd(BKV3dScale(right, -(x - lastX) * perPixel), BKV3dScale(up, -(y - lastY) * perPixel));
    camera->position = BKV3dAdd(camera->position, move);
    camera->focalPoint = BKV3dAdd(camera->focalPoint, move);
    return BKSlabCameraOK;
}

BKSlabCameraStatus BKSlabCameraZoom(BKSlabCamera *camera, double centreY, double lastY, double y)
{
    if (camera == NULL || !(camera->parallelScale > 0) || !isfinite(camera->parallelScale) ||
        !(centreY > 0) || !isfinite(centreY) || !isfinite(lastY) || !isfinite(y))
        return BKSlabCameraBadInput;
    double factor = pow(1.1, 10.0 * (y - lastY) / centreY);
    double scale = camera->parallelScale / factor;
    if (!(scale > 0) || !isfinite(scale)) return BKSlabCameraBadInput;
    camera->parallelScale = scale;
    return BKSlabCameraOK;
}

int BKSlabCameraBoxContainsStrictly(const BKSlabCameraBox *box, BKVec3d p)
{
    if (box == NULL) return 0;
    return p.x > box->min.x && p.x < box->max.x &&
           p.y > box->min.y && p.y < box->max.y &&
           p.z > box->min.z && p.z < box->max.z;
}

BKSlabCameraStatus BKSlabCameraMoveAlongView(BKSlabCamera *camera, double distance, const BKSlabCameraBox *box)
{
    float cosines[9];
    if (!isfinite(distance) || !BKSlabCameraCosines(camera, cosines)) return BKSlabCameraBadInput;
    double eyeToFocal = BKV3dLength(BKV3dSub(camera->focalPoint, camera->position));
    BKVec3d step = BKV3d((double)cosines[6] * distance, (double)cosines[7] * distance, (double)cosines[8] * distance);
    BKVec3d eye = BKV3dAdd(camera->position, step);

    BKSlabCameraStatus status = BKSlabCameraOK;
    BKSlabCamera c = *camera;
    if (box != NULL && !BKSlabCameraBoxContainsStrictly(box, eye)) {
        status = BKSlabCameraRefused;   // classic: the slab stops at the scan's edge
    } else {
        c.position = eye;
        c.focalPoint = BKV3dAdd(camera->focalPoint, step);
    }
    // Classic: the eye-to-focal distance is set again along the (new) direction, and "up" is
    // straightened, also when the move was refused.
    c.focalPoint = BKV3dAddScaled(c.position, BKSlabCameraDirection(&c), eyeToFocal);
    if (BKSlabCameraOrthogonalizeUp(&c) != BKSlabCameraOK) return BKSlabCameraBadInput;
    *camera = c;
    return status;
}

BKSlabCameraStatus BKSlabCameraYawPitch(BKSlabCamera *camera, double yawDegrees, double pitchDegrees)
{
    if (!BKSCUsable(camera) || !isfinite(yawDegrees) || !isfinite(pitchDegrees)) return BKSlabCameraBadInput;
    BKSlabCamera c = *camera;
    BKVec3d upAxis = BKV3dNormalize(c.viewUp);

    // Yaw: the focal point turns around the "up" axis through the eye ("up" itself is unchanged).
    c.focalPoint = BKV3dAdd(c.position, BKSCRotate(BKV3dSub(c.focalPoint, c.position), upAxis, yawDegrees));

    // Pitch: the focal point turns around the camera's right axis (as it is after the yaw)
    // through the eye; "up" keeps its stored value and is straightened below.
    BKVec3d right;
    if (!BKSlabCameraAxes(&c, &right, NULL)) return BKSlabCameraBadInput;
    c.focalPoint = BKV3dAdd(c.position, BKSCRotate(BKV3dSub(c.focalPoint, c.position), right, pitchDegrees));

    if (BKSlabCameraOrthogonalizeUp(&c) != BKSlabCameraOK) return BKSlabCameraBadInput;
    *camera = c;
    return BKSlabCameraOK;
}

BKSlabCameraStatus BKSlabCameraSetWindowCenter(BKSlabCamera *camera, double pointX, double pointY,
                                               double frameWidth, double frameHeight,
                                               int32_t renderWidth, int32_t renderHeight)
{
    BKVec3d right, up;
    if (!BKSlabCameraAxes(camera, &right, &up) || !(camera->parallelScale > 0) ||
        !(frameWidth > 0) || !(frameHeight > 0) || renderWidth <= 0 || renderHeight <= 0 ||
        !isfinite(pointX) || !isfinite(pointY) || !isfinite(frameWidth) || !isfinite(frameHeight))
        return BKSlabCameraBadInput;

    double halfW = frameWidth / 2.0, halfH = frameHeight / 2.0;
    double targetX = -(pointX - halfW), targetY = -(pointY - halfH);                       // frame points
    double oldX = camera->windowCenterX * halfW, oldY = camera->windowCenterY * halfH;
    if (oldX == targetX && oldY == targetY) return BKSlabCameraOK;                         // already there

    double newCenterX = targetX / halfW, newCenterY = targetY / halfH;

    // Classic rule (see the header): the screen point (halfW - (old - target) * 10000, ...) in
    // render pixels, taken to the plane of the focal point with the NEW window centre ...
    double displayX = halfW - (oldX - targetX) * 10000.0;
    double displayY = halfH - (oldY - targetY) * 10000.0;
    double halfViewWidth = camera->parallelScale * (double)renderWidth / (double)renderHeight;
    double offsetRight = halfViewWidth * (2.0 * displayX / (double)renderWidth - 1.0 + newCenterX);
    double offsetUp = camera->parallelScale * (2.0 * displayY / (double)renderHeight - 1.0 + newCenterY);
    // ... and eye + focal point move by 1/10000 of the way from that point to the focal point.
    BKVec3d move = BKV3dAdd(BKV3dScale(right, -0.0001 * offsetRight), BKV3dScale(up, -0.0001 * offsetUp));

    camera->windowCenterX = newCenterX;
    camera->windowCenterY = newCenterY;
    camera->position = BKV3dAdd(camera->position, move);
    camera->focalPoint = BKV3dAdd(camera->focalPoint, move);
    return BKSlabCameraOK;
}

void BKSlabCameraGetWindowCenterPoint(const BKSlabCamera *camera, double frameWidth, double frameHeight,
                                      double *x, double *y)
{
    if (camera == NULL) return;
    if (x) *x = -(camera->windowCenterX * (frameWidth / 2.0));
    if (y) *y = camera->windowCenterY * (frameHeight / 2.0);
}

int BKSlabCameraScanBox(BKVec3d origin, const BKVec3d axes[3], BKVec3d spacing,
                        const int32_t indexMin[3], const int32_t indexMax[3], double scale,
                        BKSlabCameraBox *box)
{
    if (axes == NULL || indexMin == NULL || indexMax == NULL || box == NULL) return 0;
    if (!BKSCFinite3(origin) || !BKSCFinite3(spacing) || !(scale > 0) || !isfinite(scale)) return 0;
    double step[3] = { spacing.x, spacing.y, spacing.z };
    for (int a = 0; a < 3; a++)
        if (!BKSCFinite3(axes[a]) || indexMax[a] < indexMin[a]) return 0;

    BKSlabCameraBox b = { BKV3d(INFINITY, INFINITY, INFINITY), BKV3d(-INFINITY, -INFINITY, -INFINITY) };
    for (int corner = 0; corner < 8; corner++) {
        BKVec3d p = origin;
        for (int a = 0; a < 3; a++) {
            int32_t index = ((corner >> a) & 1) ? indexMax[a] : indexMin[a];
            p = BKV3dAddScaled(p, axes[a], (double)index * step[a]);
        }
        p = BKV3dScale(p, scale);
        b.min = BKV3dMin(b.min, p);
        b.max = BKV3dMax(b.max, p);
    }
    *box = b;
    return 1;
}

BKSlabCameraStatus BKSlabCameraReset(BKSlabCamera *camera, const BKSlabCameraBox *box, double eyeOffset)
{
    if (camera == NULL || box == NULL || !BKSCFinite3(box->min) || !BKSCFinite3(box->max) ||
        !(eyeOffset > 0) || !isfinite(eyeOffset))
        return BKSlabCameraBadInput;
    BKVec3d centre = BKV3dScale(BKV3dAdd(box->min, box->max), 0.5);
    double radius = 0.5 * BKV3dLength(BKV3dSub(box->max, box->min));
    if (!(radius > 0)) radius = 0.5;
    camera->focalPoint = centre;
    camera->position = BKV3d(centre.x + eyeOffset, centre.y, centre.z);   // left view: looks towards -x
    camera->viewUp = BKV3d(0, 0, 1);
    camera->parallelScale = radius;
    return BKSlabCameraOK;
}

double BKSlabCameraLargestDifference(const BKSlabCamera *a, const BKSlabCamera *b)
{
    if (a == NULL || b == NULL) return INFINITY;
    double values[] = {
        a->position.x - b->position.x, a->position.y - b->position.y, a->position.z - b->position.z,
        a->focalPoint.x - b->focalPoint.x, a->focalPoint.y - b->focalPoint.y, a->focalPoint.z - b->focalPoint.z,
        a->viewUp.x - b->viewUp.x, a->viewUp.y - b->viewUp.y, a->viewUp.z - b->viewUp.z,
        a->parallelScale - b->parallelScale,
        a->windowCenterX - b->windowCenterX, a->windowCenterY - b->windowCenterY,
    };
    double largest = 0;
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        double v = fabs(values[i]);
        if (!(v <= largest)) largest = v;   // NaN counts as the largest
    }
    return largest;
}
