// BorosKitRender: cropping-box maths (plain C). See include/BKBoxWidgetMath.h for what each
// function does and the porting notes.

#include "BKBoxWidgetMath.h"
#include "BKCameraMath.h"   // BKRotateVectorAroundAxisAroundAxis
#include <math.h>

// What: v scaled to length 1, or v unchanged when it is (almost) zero.
static BKVec3d BKBoxNormalize(BKVec3d v)
{
    double len = BKV3dLength(v);
    return len > 1e-12 ? BKV3dDiv(v, len) : v;
}

BKOrientedBox BKBoxMakeAxisAligned(BKVec3d boxMin, BKVec3d boxMax)
{
    BKOrientedBox b;
    b.centre = BKV3dScale(BKV3dAdd(boxMin, boxMax), 0.5);
    b.axis[0] = BKV3d(1, 0, 0);
    b.axis[1] = BKV3d(0, 1, 0);
    b.axis[2] = BKV3d(0, 0, 1);
    for (int k = 0; k < 3; k++) b.halfSize[k] = 0.5 * fabs(BKV3dComponent(boxMax, k) - BKV3dComponent(boxMin, k));
    return b;
}

bool BKBoxFromHandles(const BKVec3d faceCentres[6], BKVec3d centre, BKOrientedBox *out)
{
    if (out == NULL) return false;
    BKOrientedBox b;
    b.centre = centre;
    for (int k = 0; k < 3; k++) {
        // The two opposite face centres lie on the box's k-th axis through its centre;
        // half their distance is the half size along that axis.
        BKVec3d span = BKV3dSub(faceCentres[2 * k + 1], faceCentres[2 * k]);
        double len = BKV3dLength(span);
        if (!(len > 1e-12)) return false;
        b.axis[k] = BKV3dDiv(span, len);
        b.halfSize[k] = 0.5 * len;
    }
    *out = b;
    return true;
}

BKVec3d BKBoxHandlePosition(BKOrientedBox box, int handle)
{
    if (handle < 0 || handle >= 6) return box.centre;
    int k = handle / 2;
    double side = (handle % 2) ? 1.0 : -1.0;
    return BKV3dAddScaled(box.centre, box.axis[k], side * box.halfSize[k]);
}

BKVec3d BKBoxFaceNormal(BKOrientedBox box, int face)
{
    if (face < 0 || face >= 6) return BKV3d(0, 0, 0);
    return BKV3dScale(box.axis[face / 2], (face % 2) ? 1.0 : -1.0);
}

void BKBoxCorners(BKOrientedBox box, BKVec3d out[8])
{
    // Signs along axis 0, 1, 2 for each corner, in VTK's hexahedron numbering.
    static const int signs[8][3] = {
        {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
        {-1, -1, 1},  {1, -1, 1},  {1, 1, 1},  {-1, 1, 1},
    };
    for (int i = 0; i < 8; i++) {
        BKVec3d p = box.centre;
        for (int k = 0; k < 3; k++) p = BKV3dAddScaled(p, box.axis[k], signs[i][k] * box.halfSize[k]);
        out[i] = p;
    }
}

double BKBoxDiagonal(BKOrientedBox box)
{
    return 2.0 * sqrt(box.halfSize[0] * box.halfSize[0] + box.halfSize[1] * box.halfSize[1] +
                      box.halfSize[2] * box.halfSize[2]);
}

int BKBoxPickHandle(BKOrientedBox box, BKVec3d origin, BKVec3d direction,
                    double radiusAtOrigin, double radiusPerDistance, double *distance)
{
    BKVec3d d = BKBoxNormalize(direction);
    int best = -1;
    double bestT = INFINITY;
    for (int h = 0; h < BKBoxHandleCount; h++) {
        BKVec3d p = BKBoxHandlePosition(box, h);
        // Closest approach of the ray to the handle centre: t = (p - origin) . d.
        double t = BKV3dDot(BKV3dSub(p, origin), d);
        if (t < 0) continue;   // behind the viewer
        double miss = BKV3dLength(BKV3dSub(p, BKV3dAddScaled(origin, d, t)));
        double radius = radiusAtOrigin + radiusPerDistance * t;
        if (miss <= radius && t < bestT) {
            bestT = t;
            best = h;
        }
    }
    if (best >= 0 && distance) *distance = bestT;
    return best;
}

int BKBoxPickFace(BKOrientedBox box, BKVec3d origin, BKVec3d direction, double *distance)
{
    BKVec3d d = BKBoxNormalize(direction);
    // Classic "slab" test in the box's own axes: along each axis the ray is inside the box
    // between two distances; the ray hits the box if those three intervals overlap. The
    // face where the latest interval starts is the face the ray enters through.
    double tEnter = -INFINITY, tLeave = INFINITY;
    int enterFace = -1;
    BKVec3d rel = BKV3dSub(origin, box.centre);
    for (int k = 0; k < 3; k++) {
        double o = BKV3dDot(rel, box.axis[k]);
        double v = BKV3dDot(d, box.axis[k]);
        double h = box.halfSize[k];
        if (fabs(v) < 1e-12) {
            if (o < -h || o > h) return -1;   // parallel to this pair of faces and outside
            continue;
        }
        double t1 = (-h - o) / v, t2 = (h - o) / v;
        // Moving towards +axis, the ray enters through the -face; otherwise through the +face.
        int face = (v > 0) ? 2 * k : 2 * k + 1;
        double tNear = fmin(t1, t2), tFar = fmax(t1, t2);
        if (tNear > tEnter) { tEnter = tNear; enterFace = face; }
        if (tFar < tLeave) tLeave = tFar;
    }
    if (enterFace < 0 || tEnter > tLeave || tEnter < 0) return -1;
    if (distance) *distance = tEnter;
    return enterFace;
}

void BKBoxMoveFace(BKOrientedBox *box, int face, BKVec3d motion, double minHalfSize)
{
    if (box == NULL || face < 0 || face >= 6) return;
    int k = face / 2;
    BKVec3d n = BKBoxFaceNormal(*box, face);
    // How far the face moves outwards (negative = inwards).
    double move = BKV3dDot(motion, n);
    // The box is 2*halfSize long; moving one face by `move` changes that by `move`.
    double newHalf = box->halfSize[k] + 0.5 * move;
    if (newHalf < minHalfSize) {
        newHalf = minHalfSize;
        move = 2.0 * (newHalf - box->halfSize[k]);
    }
    box->halfSize[k] = newHalf;
    // The opposite face stays put, so the centre moves half as far as the face.
    box->centre = BKV3dAddScaled(box->centre, n, 0.5 * move);
}

void BKBoxTranslate(BKOrientedBox *box, BKVec3d motion)
{
    if (box) box->centre = BKV3dAdd(box->centre, motion);
}

void BKBoxScale(BKOrientedBox *box, double factor, double minHalfSize)
{
    if (box == NULL || !(factor > 0)) return;
    for (int k = 0; k < 3; k++) box->halfSize[k] = fmax(box->halfSize[k] * factor, minHalfSize);
}

void BKBoxRotate(BKOrientedBox *box, BKVec3d axis, double radians)
{
    if (box == NULL || !(BKV3dLength(axis) > 1e-12)) return;
    for (int k = 0; k < 3; k++) box->axis[k] = BKBoxNormalize(BKRotateVectorAroundAxis(box->axis[k], axis, radians));
    // Keep the three axes exactly perpendicular (removes rounding drift over many drags).
    box->axis[1] = BKBoxNormalize(BKV3dSub(box->axis[1], BKV3dScale(box->axis[0], BKV3dDot(box->axis[1], box->axis[0]))));
    BKVec3d z = BKBoxNormalize(BKV3dCross(box->axis[0], box->axis[1]));
    // Keep the original handedness of axis 2.
    box->axis[2] = BKV3dDot(z, box->axis[2]) >= 0 ? z : BKV3dNeg(z);
}

bool BKBoxRotationForDrag(BKOrientedBox box, BKVec3d viewDirection, BKVec3d motion,
                          BKVec3d *axis, double *radians)
{
    // A point on the front face moving with the mouse needs the box to turn around an axis
    // perpendicular to both the motion and the viewing direction.
    BKVec3d a = BKV3dCross(motion, BKBoxNormalize(viewDirection));
    double len = BKV3dLength(a), diagonal = BKBoxDiagonal(box);
    if (!(len > 1e-12) || !(diagonal > 1e-12)) return false;
    if (axis) *axis = BKV3dDiv(a, len);
    if (radians) *radians = 2.0 * M_PI * BKV3dLength(motion) / diagonal;
    return true;
}

double BKBoxScaleFactorForDrag(BKOrientedBox box, BKVec3d motion, double upwards)
{
    double diagonal = BKBoxDiagonal(box);
    if (!(diagonal > 1e-12)) return 1.0;
    double change = BKV3dLength(motion) / diagonal;
    double factor = (upwards > 0) ? 1.0 + change : 1.0 - change;
    return fmax(factor, 0.1);
}

bool BKBoxAffineMap(BKOrientedBox from, BKOrientedBox to, double m[16])
{
    // p' = to.centre + sum_k (to.half_k / from.half_k) * to.axis_k * (from.axis_k . (p - from.centre))
    // Linear part L = sum_k s_k * to.axis_k (outer) from.axis_k; translation = to.centre - L * from.centre.
    double L[3][3] = {{0}};
    for (int k = 0; k < 3; k++) {
        if (!(from.halfSize[k] > 1e-12)) return false;
        double s = to.halfSize[k] / from.halfSize[k];
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                L[r][c] += s * BKV3dComponent(to.axis[k], r) * BKV3dComponent(from.axis[k], c);
    }
    for (int r = 0; r < 3; r++) {
        double t = BKV3dComponent(to.centre, r);
        for (int c = 0; c < 3; c++) {
            m[4 * r + c] = L[r][c];
            t -= L[r][c] * BKV3dComponent(from.centre, c);
        }
        m[4 * r + 3] = t;
    }
    m[12] = 0; m[13] = 0; m[14] = 0; m[15] = 1;
    return true;
}

void BKBoxClipPlanes(BKOrientedBox box, float out[24])
{
    for (int f = 0; f < 6; f++) {
        // Outward normal: cutting the side it points to removes everything outside this face.
        BKVec3d n = BKBoxFaceNormal(box, f);
        BKVec3d p = BKBoxHandlePosition(box, f);
        out[4 * f + 0] = (float)n.x;
        out[4 * f + 1] = (float)n.y;
        out[4 * f + 2] = (float)n.z;
        out[4 * f + 3] = (float)(-BKV3dDot(n, p));
    }
}

bool BKBoxContainsPoint(BKOrientedBox box, BKVec3d p)
{
    BKVec3d rel = BKV3dSub(p, box.centre);
    for (int k = 0; k < 3; k++)
        if (fabs(BKV3dDot(rel, box.axis[k])) > box.halfSize[k] + 1e-9) return false;
    return true;
}
