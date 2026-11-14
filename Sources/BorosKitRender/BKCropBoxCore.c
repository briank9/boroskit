// BorosKitRender: native cropping box - interaction and drawing geometry (plain C).
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKCropBoxCore.h for what each function does and the porting notes.

#include "BKCropBoxCore.h"
#include <math.h>

// What: v scaled to length 1, or v unchanged when it is (almost) zero.
static BKVec3d BKCropNormalize(BKVec3d v)
{
    double len = BKV3dLength(v);
    return len > 1e-12 ? BKV3dDiv(v, len) : v;
}

// What: signed value of a packed plane at p (> 0 = on the cut side).
static double BKCropPlaneValue(const float *plane, BKVec3d p)
{
    return (double)plane[0] * p.x + (double)plane[1] * p.y + (double)plane[2] * p.z + (double)plane[3];
}

bool BKCutPlanesKeepPoint(const float *planes, uint32_t count, BKVec3d p)
{
    if (planes == NULL) return true;
    for (uint32_t i = 0; i < count && i < BK_CROP_MAX_CUT_PLANES; i++)
        if (BKCropPlaneValue(planes + 4 * i, p) > 1e-9) return false;
    return true;
}

double BKCropBoxScreenRadius(BKCameraFrame camera, double viewHeight, BKVec3d point, double radiusPoints)
{
    // Depth of the point in front of the camera: only matters for a perspective view.
    double depth = BKV3dDot(BKV3dSub(point, camera.position), camera.direction);
    if (camera.perspective && depth < 1e-6) depth = 1e-6;
    return radiusPoints * BKCameraMillimetresPerViewPoint(camera, viewHeight, depth);
}

// What: the visible handle nearest to the ray origin that the ray passes close enough to, or -1.
// Like BKBoxPickHandle, but skipping handles cut away by the planes.
static int BKCropPickVisibleHandle(BKOrientedBox box, BKVec3d origin, BKVec3d dir,
                                   double radiusAtOrigin, double radiusPerDistance,
                                   const float *cut, uint32_t cutCount, double *distance)
{
    int best = -1;
    double bestT = INFINITY;
    for (int h = 0; h < BKBoxHandleCount; h++) {
        BKVec3d p = BKBoxHandlePosition(box, h);
        if (!BKCutPlanesKeepPoint(cut, cutCount, p)) continue;   // not shown, so not grabbable
        double t = BKV3dDot(BKV3dSub(p, origin), dir);            // closest approach along the ray
        if (t < 0) continue;
        double miss = BKV3dLength(BKV3dSub(p, BKV3dAddScaled(origin, dir, t)));
        if (miss <= radiusAtOrigin + radiusPerDistance * t && t < bestT) {
            bestT = t;
            best = h;
        }
    }
    if (best >= 0 && distance) *distance = bestT;
    return best;
}

bool BKCropBoxBeginDrag(BKOrientedBox box, BKCameraFrame camera, double viewWidth, double viewHeight,
                        double x, double yDown, int32_t button, bool shift, double pickRadiusPoints,
                        const float *cutPlanes, uint32_t cutPlaneCount, BKCropBoxDrag *drag)
{
    if (drag == NULL || viewWidth <= 0 || viewHeight <= 0) return false;
    BKVec3d origin, dir;
    BKCameraRayThroughViewPoint(camera, viewWidth, viewHeight, x, yDown, &origin, &dir);
    dir = BKCropNormalize(dir);
    // Orthographic: start the ray in front of the whole box (the camera position may lie inside
    // the volume, e.g. in thick-slab mode) so that everything visible can be picked.
    if (!camera.perspective) origin = BKV3dSub(origin, BKV3dScale(dir, BKV3dLength(BKV3dSub(box.centre, origin)) + BKBoxDiagonal(box) + 1.0));

    // Handle tolerance in mm: constant on screen (orthographic: same everywhere; perspective:
    // grows with the distance from the eye).
    double radiusAtOrigin = camera.perspective ? 0 : pickRadiusPoints * BKCameraMillimetresPerViewPoint(camera, viewHeight, 0);
    double radiusPerDistance = camera.perspective ? pickRadiusPoints * BKCameraMillimetresPerViewPoint(camera, viewHeight, 1.0) : 0;

    double t = 0;
    int handle = BKCropPickVisibleHandle(box, origin, dir, radiusAtOrigin, radiusPerDistance, cutPlanes, cutPlaneCount, &t);
    int face = -1;
    if (handle < 0) {
        face = BKBoxPickFace(box, origin, dir, &t);
        // A face point cut away by the slab is not shown: the click goes to the camera instead.
        if (face >= 0 && !BKCutPlanesKeepPoint(cutPlanes, cutPlaneCount, BKV3dAddScaled(origin, dir, t))) face = -1;
    }
    if (handle < 0 && face < 0) return false;

    BKCropBoxDrag d = { BKCropDragNone, -1, -1, -1, 0, 0, 0.0 };
    if (button == BKCropButtonRight) d.mode = BKCropDragScale;
    else if (button == BKCropButtonMiddle) d.mode = BKCropDragTranslate;
    else if (handle >= 0 && handle < 6 && !shift) d.mode = BKCropDragMoveFace;
    else if (handle == BKBoxHandleCentre || shift) d.mode = BKCropDragTranslate;
    else d.mode = BKCropDragRotate;
    d.part = (handle >= 0) ? handle : face;

    // The highlights the classic box widget shows: red handle + yellow face for a face move,
    // yellow face for a turn, red centre handle + green outline when moving by the centre,
    // green outline when the whole box is moved / resized otherwise.
    switch (d.mode) {
        case BKCropDragMoveFace: d.highlightHandle = handle; d.highlightFace = handle; break;
        case BKCropDragRotate: d.highlightFace = face; break;
        default:
            d.highlightHandle = (handle == BKBoxHandleCentre) ? BKBoxHandleCentre : -1;
            d.highlightOutline = 1;
            break;
    }
    d.depth = BKV3dDot(BKV3dSub(BKV3dAddScaled(origin, dir, t), camera.position), camera.direction);
    *drag = d;
    return true;
}

bool BKCropBoxContinueDrag(BKOrientedBox *box, const BKCropBoxDrag *drag, BKCameraFrame camera,
                           double viewHeight, double dx, double dyDown, double minimumEdge)
{
    if (box == NULL || drag == NULL || drag->mode == BKCropDragNone) return false;
    if (dx == 0 && dyDown == 0) return false;
    BKVec3d motion = BKCameraWorldDeltaForViewDelta(camera, viewHeight, drag->depth, dx, dyDown);
    double minHalf = 0.5 * fmax(minimumEdge, 0.0);
    BKOrientedBox next = *box;
    switch (drag->mode) {
        case BKCropDragMoveFace:
            BKBoxMoveFace(&next, drag->part, motion, minHalf);
            break;
        case BKCropDragTranslate:
            BKBoxTranslate(&next, motion);
            break;
        case BKCropDragScale:
            // Mouse up on the screen (dyDown < 0) makes the box bigger.
            BKBoxScale(&next, BKBoxScaleFactorForDrag(*box, motion, -dyDown), minHalf);
            break;
        case BKCropDragRotate: {
            BKVec3d axis;
            double radians = 0;
            if (BKBoxRotationForDrag(*box, camera.direction, motion, &axis, &radians)) BKBoxRotate(&next, axis, radians);
            break;
        }
        default:
            return false;
    }
    bool changed = !BKBoxNearlyEqual(*box, next, 0.0);
    *box = next;
    return changed;
}

// What: cuts segment a-b by the planes. Returns false when nothing is left; otherwise a/b are
// replaced by the ends of the kept part.
static bool BKCropClipSegment(BKVec3d *a, BKVec3d *b, const float *cut, uint32_t count)
{
    for (uint32_t i = 0; cut && i < count && i < BK_CROP_MAX_CUT_PLANES; i++) {
        const float *pl = cut + 4 * i;
        double da = BKCropPlaneValue(pl, *a), db = BKCropPlaneValue(pl, *b);
        if (da > 0 && db > 0) return false;   // wholly on the cut side
        if (da <= 0 && db <= 0) continue;     // wholly kept by this plane
        double t = da / (da - db);            // where the segment crosses the plane
        BKVec3d cross = BKV3dAddScaled(*a, BKV3dSub(*b, *a), t);
        if (da > 0) *a = cross; else *b = cross;
    }
    return true;
}

uint32_t BKCropBoxOutline(BKOrientedBox box, const float *cutPlanes, uint32_t cutPlaneCount, BKVec3f out[24])
{
    // The 12 edges in the corner numbering of BKBoxCorners: bottom ring, top ring, uprights.
    static const int edges[12][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 0},
        {4, 5}, {5, 6}, {6, 7}, {7, 4},
        {0, 4}, {1, 5}, {2, 6}, {3, 7},
    };
    BKVec3d c[8];
    BKBoxCorners(box, c);
    uint32_t n = 0;
    for (int e = 0; e < 12; e++) {
        BKVec3d a = c[edges[e][0]], b = c[edges[e][1]];
        if (!BKCropClipSegment(&a, &b, cutPlanes, cutPlaneCount)) continue;
        out[n++] = BKV3f((float)a.x, (float)a.y, (float)a.z);
        out[n++] = BKV3f((float)b.x, (float)b.y, (float)b.z);
    }
    return n;
}

uint32_t BKCropBoxFacePolygon(BKOrientedBox box, int32_t face, const float *cutPlanes, uint32_t cutPlaneCount,
                              BKVec3f out[BK_CROP_FACE_MAX_POINTS])
{
    if (face < 0 || face >= 6) return 0;
    // The 4 corners of each face, in order around it (corner numbering of BKBoxCorners).
    static const int faces[6][4] = {
        {0, 3, 7, 4},   // -X
        {1, 5, 6, 2},   // +X
        {0, 4, 5, 1},   // -Y
        {3, 2, 6, 7},   // +Y
        {0, 1, 2, 3},   // -Z
        {4, 7, 6, 5},   // +Z
    };
    BKVec3d c[8];
    BKBoxCorners(box, c);
    BKVec3d poly[BK_CROP_FACE_MAX_POINTS], next[BK_CROP_FACE_MAX_POINTS];
    uint32_t n = 4;
    for (int i = 0; i < 4; i++) poly[i] = c[faces[face][i]];

    // Cut the convex polygon by one plane at a time: walk its edges, keep the corners on the kept
    // side and add the crossing point wherever an edge passes from one side to the other.
    for (uint32_t p = 0; cutPlanes && p < cutPlaneCount && p < BK_CROP_MAX_CUT_PLANES && n > 0; p++) {
        const float *pl = cutPlanes + 4 * p;
        uint32_t m = 0;
        for (uint32_t i = 0; i < n; i++) {
            BKVec3d a = poly[i], b = poly[(i + 1) % n];
            double da = BKCropPlaneValue(pl, a), db = BKCropPlaneValue(pl, b);
            if (da <= 0 && m < BK_CROP_FACE_MAX_POINTS) next[m++] = a;
            if (((da <= 0) != (db <= 0)) && m < BK_CROP_FACE_MAX_POINTS)
                next[m++] = BKV3dAddScaled(a, BKV3dSub(b, a), da / (da - db));
        }
        n = m;
        for (uint32_t i = 0; i < n; i++) poly[i] = next[i];
    }
    if (n < 3) return 0;
    for (uint32_t i = 0; i < n; i++) out[i] = BKV3f((float)poly[i].x, (float)poly[i].y, (float)poly[i].z);
    return n;
}

// What: YES when all three components are ordinary numbers (not NaN / infinite).
static bool BKCropFinite3(BKVec3d v)
{
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

bool BKBoxFromSixPlanes(const double origins[18], const double normals[18], double scale, BKOrientedBox *out)
{
    if (origins == NULL || normals == NULL || out == NULL || !(scale > 0) || !isfinite(scale)) return false;
    BKVec3d axes[3];
    double half[3], mid[3];
    for (int k = 0; k < 3; k++) {
        const double *o0 = origins + 6 * k, *o1 = origins + 6 * k + 3;
        const double *n0 = normals + 6 * k, *n1 = normals + 6 * k + 3;
        BKVec3d p0 = BKV3dScale(BKV3d(o0[0], o0[1], o0[2]), scale);
        BKVec3d p1 = BKV3dScale(BKV3d(o1[0], o1[1], o1[2]), scale);
        BKVec3d a = BKV3d(n0[0], n0[1], n0[2]);
        BKVec3d b = BKV3d(n1[0], n1[1], n1[2]);
        if (!BKCropFinite3(p0) || !BKCropFinite3(p1) || !BKCropFinite3(a) || !BKCropFinite3(b)) return false;
        if (!(BKV3dLength(a) > 1e-12) || !(BKV3dLength(b) > 1e-12)) return false;
        a = BKV3dNormalize(a);
        b = BKV3dNormalize(b);
        if (fabs(BKV3dDot(a, b)) < 0.9999) return false;   // the two planes of a pair must be parallel
        // Axis k points from the "minus" face to the "plus" face.
        double s = BKV3dDot(BKV3dSub(p1, p0), a);
        if (s < 0) { a = BKV3dNeg(a); s = -s; }
        if (!(s > 1e-9)) return false;                      // flat box
        axes[k] = a;
        half[k] = 0.5 * s;
        mid[k] = BKV3dDot(BKV3dScale(BKV3dAdd(p0, p1), 0.5), a);              // centre's position along the axis
    }
    // The three directions must be perpendicular (a box); tidy up the rounding afterwards.
    if (fabs(BKV3dDot(axes[0], axes[1])) > 1e-3 || fabs(BKV3dDot(axes[0], axes[2])) > 1e-3 ||
        fabs(BKV3dDot(axes[1], axes[2])) > 1e-3) return false;
    BKOrientedBox b;
    b.axis[0] = axes[0];
    b.axis[1] = BKCropNormalize(BKV3dSub(axes[1], BKV3dScale(axes[0], BKV3dDot(axes[1], axes[0]))));
    BKVec3d z = BKCropNormalize(BKV3dCross(b.axis[0], b.axis[1]));
    b.axis[2] = BKV3dDot(z, axes[2]) >= 0 ? z : BKV3dNeg(z);
    b.centre = BKV3dAdd(BKV3dAdd(BKV3dScale(b.axis[0], mid[0]), BKV3dScale(b.axis[1], mid[1])), BKV3dScale(b.axis[2], mid[2]));
    for (int k = 0; k < 3; k++) b.halfSize[k] = half[k];
    *out = b;
    return true;
}

void BKBoxKeptSidePlanes(BKOrientedBox box, double scale, double origins[18], double normals[18])
{
    for (int f = 0; f < 6; f++) {
        BKVec3d o = BKV3dScale(BKBoxHandlePosition(box, f), scale);
        BKVec3d n = BKV3dNeg(BKBoxFaceNormal(box, f));   // into the box: the kept side
        for (int c = 0; c < 3; c++) {
            origins[3 * f + c] = BKV3dComponent(o, c);
            normals[3 * f + c] = BKV3dComponent(n, c);
        }
    }
}

void BKBoxAxisAlignedBounds(BKOrientedBox box, BKVec3d *boxMin, BKVec3d *boxMax)
{
    BKVec3d c[8];
    BKBoxCorners(box, c);
    BKVec3d lo = c[0], hi = c[0];
    for (int i = 1; i < 8; i++) {
        lo = BKV3dMin(lo, c[i]);
        hi = BKV3dMax(hi, c[i]);
    }
    if (boxMin) *boxMin = lo;
    if (boxMax) *boxMax = hi;
}

bool BKBoxNearlyEqual(BKOrientedBox a, BKOrientedBox b, double tolerance)
{
    if (BKV3dLength(BKV3dSub(a.centre, b.centre)) > tolerance) return false;
    for (int k = 0; k < 3; k++) {
        if (fabs(a.halfSize[k] - b.halfSize[k]) > tolerance) return false;
        // Directions compared through a point on each face: a turn of angle x moves the face
        // centre by about halfSize * x, so the same tolerance in mm applies.
        double reach = fmax(a.halfSize[k], 1.0);
        if (BKV3dLength(BKV3dSub(a.axis[k], b.axis[k])) * reach > tolerance) return false;
    }
    return true;
}

double BKCropBoxMinimumEdge(double largestVoxelSize)
{
    double voxel = (largestVoxelSize > 0 && isfinite(largestVoxelSize)) ? largestVoxelSize : 0;
    return fmax(2.0, 2.0 * voxel);
}
