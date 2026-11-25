// BorosKitRender: BKMPRGeometryCore - see BKMPRGeometryCore.h.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKMPRGeometryCore.h"

#include <math.h>
#include <string.h>

static BKVec3d BKMulPoint(const double m[16], BKVec3d p)
{
    return BKV3d(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                 m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                 m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
}

static BKVec3d BKMulDirection(const double m[16], BKVec3d d)
{
    return BKV3d(m[0] * d.x + m[4] * d.y + m[8] * d.z,
                 m[1] * d.x + m[5] * d.y + m[9] * d.z,
                 m[2] * d.x + m[6] * d.y + m[10] * d.z);
}

static int BKFinite(BKVec3d v) { return isfinite(v.x) && isfinite(v.y) && isfinite(v.z); }

BKMPRFrame BKMPRFrameMake(BKVec3d centre)
{
    BKMPRFrame f;
    f.centre = centre;
    f.axis[0] = BKV3d(1, 0, 0);
    f.axis[1] = BKV3d(0, 1, 0);
    f.axis[2] = BKV3d(0, 0, 1);
    return f;
}

// The three views' directions. right x down = normal in every view (a right-handed screen with y down), so
// a positive turn about the normal moves "right" towards "down" = clockwise on screen.
void BKMPRViewAxes(const BKMPRFrame *f, BKMPRView view, BKVec3d *right, BKVec3d *down, BKVec3d *normal)
{
    BKVec3d r, d, n;
    switch (view) {
        case BKMPRViewCoronal: r = f->axis[0]; d = BKV3dNeg(f->axis[2]); n = f->axis[1]; break;
        case BKMPRViewSagittal: r = f->axis[1]; d = BKV3dNeg(f->axis[2]); n = BKV3dNeg(f->axis[0]); break;
        default: r = f->axis[0]; d = f->axis[1]; n = f->axis[2]; break;
    }
    if (right) *right = r;
    if (down) *down = d;
    if (normal) *normal = n;
}

// Rodrigues' rotation of v about the unit axis k by angle a (radians, right-handed).
static BKVec3d BKRotate(BKVec3d v, BKVec3d k, double a)
{
    double c = cos(a), s = sin(a);
    return BKV3dAdd(BKV3dAdd(BKV3dScale(v, c), BKV3dScale(BKV3dCross(k, v), s)), BKV3dScale(k, BKV3dDot(k, v) * (1.0 - c)));
}

void BKMPRRotateInView(BKMPRFrame *frame, BKMPRView view, double degrees)
{
    if (frame == NULL || !isfinite(degrees)) return;
    BKVec3d n;
    BKMPRViewAxes(frame, view, NULL, NULL, &n);
    double a = degrees * 3.14159265358979323846 / 180.0;
    for (int i = 0; i < 3; i++) frame->axis[i] = BKRotate(frame->axis[i], n, a);
    BKMPRFrameOrthonormalize(frame);
}

void BKMPRFrameOrthonormalize(BKMPRFrame *f)
{
    BKVec3d x = BKV3dNormalize(f->axis[0]);
    BKVec3d y = BKV3dSub(f->axis[1], BKV3dScale(x, BKV3dDot(f->axis[1], x)));
    y = BKV3dNormalize(y);
    BKVec3d z = BKV3dCross(x, y);   // right-handed
    if (!BKFinite(x) || !BKFinite(y) || !BKFinite(z)) { *f = BKMPRFrameMake(f->centre); return; }
    f->axis[0] = x; f->axis[1] = y; f->axis[2] = z;
}

void BKMPRScanCorners(const double voxelToPatient[16], uint32_t w, uint32_t h, uint32_t d, BKVec3d corners[8])
{
    double lo = -0.5;
    for (int i = 0; i < 8; i++) {
        BKVec3d v = BKV3d((i & 1) ? w - 0.5 : lo, (i & 2) ? h - 0.5 : lo, (i & 4) ? d - 0.5 : lo);
        corners[i] = BKMulPoint(voxelToPatient, v);
    }
}

BKVec3d BKMPRClampToScan(BKVec3d point, const double patientToVoxel[16], const double voxelToPatient[16],
                         uint32_t w, uint32_t h, uint32_t d)
{
    BKVec3d v = BKMulPoint(patientToVoxel, point);
    v.x = fmin(fmax(v.x, 0.0), w > 0 ? w - 1.0 : 0.0);
    v.y = fmin(fmax(v.y, 0.0), h > 0 ? h - 1.0 : 0.0);
    v.z = fmin(fmax(v.z, 0.0), d > 0 ? d - 1.0 : 0.0);
    return BKMulPoint(voxelToPatient, v);
}

int BKMPRPictureForPlane(const BKVec3d corners[8], BKVec3d p, BKVec3d right, BKVec3d down, double spacing,
                         uint32_t maxPixels, BKMPRPicture *picture)
{
    if (!picture || !(spacing > 0) || maxPixels < 2 || !BKFinite(p)) return 0;
    right = BKV3dNormalize(right);
    down = BKV3dNormalize(down);
    if (!BKFinite(right) || !BKFinite(down) || fabs(BKV3dDot(right, down)) > 1e-6) return 0;
    double minR = INFINITY, maxR = -INFINITY, minD = INFINITY, maxD = -INFINITY;
    for (int i = 0; i < 8; i++) {
        BKVec3d rel = BKV3dSub(corners[i], p);
        double r = BKV3dDot(rel, right), dd = BKV3dDot(rel, down);
        minR = fmin(minR, r); maxR = fmax(maxR, r); minD = fmin(minD, dd); maxD = fmax(maxD, dd);
    }
    double spanR = maxR - minR, spanD = maxD - minD;
    if (!(spanR > 0) || !(spanD > 0)) return 0;
    double largest = fmax(spanR, spanD);
    if (largest / spacing > maxPixels) spacing = largest / maxPixels;
    picture->width = (uint32_t)ceil(spanR / spacing - 1e-9);
    picture->height = (uint32_t)ceil(spanD / spacing - 1e-9);
    if (picture->width < 1) picture->width = 1;
    if (picture->height < 1) picture->height = 1;
    picture->spacing = spacing;
    picture->right = right;
    picture->down = down;
    picture->normal = BKV3dCross(right, down);
    // Centre the grid on the scan's projection; pixel (0,0) centre half a pixel in from the corner.
    double extraR = picture->width * spacing - spanR, extraD = picture->height * spacing - spanD;
    picture->origin = BKV3dAdd(p, BKV3dAdd(BKV3dScale(right, minR - extraR / 2 + spacing / 2),
                                           BKV3dScale(down, minD - extraD / 2 + spacing / 2)));
    return 1;
}

BKVec3d BKMPRPictureImageToPatient(const BKMPRPicture *pic, double x, double y)
{
    return BKV3dAdd(pic->origin, BKV3dAdd(BKV3dScale(pic->right, (x - 0.5) * pic->spacing),
                                          BKV3dScale(pic->down, (y - 0.5) * pic->spacing)));
}

void BKMPRPicturePatientToImage(const BKMPRPicture *pic, BKVec3d point, double *x, double *y)
{
    BKVec3d rel = BKV3dSub(point, pic->origin);
    if (x) *x = BKV3dDot(rel, pic->right) / pic->spacing + 0.5;
    if (y) *y = BKV3dDot(rel, pic->down) / pic->spacing + 0.5;
}

void BKMPRPictureCamera(const BKMPRPicture *pic, BKVec3d *position, BKVec3d *direction, BKVec3d *up,
                        double *viewWidthMm, double *viewHeightMm)
{
    // The renderer puts the image-plane centre in the middle of the picture: half-way between pixel 0 and
    // pixel width-1 (pixel centres), i.e. image coordinate width / 2.
    if (position) *position = BKMPRPictureImageToPatient(pic, pic->width / 2.0, pic->height / 2.0);
    if (direction) *direction = pic->normal;
    if (up) *up = BKV3dNeg(pic->down);
    if (viewWidthMm) *viewWidthMm = pic->width * pic->spacing;
    if (viewHeightMm) *viewHeightMm = pic->height * pic->spacing;
}

void BKMPRColumnFrames(const double patientToVoxel[16], const BKVec3d *centres, const BKVec3d *downs,
                       const BKVec3d *slabs, uint32_t count, double rowSpacing, double slabStep, BKReformatFrame *frames)
{
    for (uint32_t i = 0; i < count; i++) {
        BKVec3d b = BKMulPoint(patientToVoxel, centres[i]);
        BKVec3d r = BKMulDirection(patientToVoxel, BKV3dScale(downs[i], rowSpacing));
        BKVec3d s = BKMulDirection(patientToVoxel, BKV3dScale(slabs[i], slabStep));
        BKReformatFrame f = { { (float)b.x, (float)b.y, (float)b.z, 0 }, { (float)r.x, (float)r.y, (float)r.z, 0 },
                              { (float)s.x, (float)s.y, (float)s.z, 0 } };
        frames[i] = f;
    }
}

int BKMPRPanoramicDirections(const BKVec3d *positions, const BKVec3d *tangents, uint32_t count, BKVec3d down,
                             BKVec3d inside, BKVec3d *downs, BKVec3d *slabs)
{
    down = BKV3dNormalize(down);
    if (!positions || !tangents || !downs || !slabs || count == 0 || !BKFinite(down)) return 0;
    BKVec3d previous = BKV3d(0, 0, 0);
    for (uint32_t i = 0; i < count; i++) {
        BKVec3d t = BKV3dSub(tangents[i], BKV3dScale(down, BKV3dDot(tangents[i], down)));
        double len = BKV3dLength(t);
        BKVec3d s;
        if (len < 1e-9) s = previous;   // the curve runs straight up/down here: keep the last direction
        else {
            s = BKV3dNormalize(BKV3dCross(BKV3dDiv(t, len), down));
            // Point towards the cheek: away from a point inside the arch. The sign is decided once from the
            // whole curve (first sample) and then kept continuous, so it cannot flip mid-curve.
            if (i == 0 && BKV3dDot(s, BKV3dSub(positions[0], inside)) < 0) s = BKV3dNeg(s);
            if (i > 0 && BKV3dDot(s, previous) < 0) s = BKV3dNeg(s);
        }
        if (!BKFinite(s) || BKV3dLength(s) < 0.5) return 0;
        slabs[i] = s;
        downs[i] = down;
        previous = s;
    }
    return 1;
}

uint32_t BKMPRSlabDepth(double thicknessMm, double stepMm)
{
    if (!(thicknessMm > 0) || !(stepMm > 0)) return 1;
    double n = floor(thicknessMm / stepMm + 1e-9) + 1;
    return n > 4096 ? 4096 : (uint32_t)n;
}

void BKMPRSetHeightBand(BKReformatParams *params, const double voxelToPatient[16], BKVec3d axis,
                        double lowMm, double highMm, int enabled)
{
    if (params == NULL) return;
    params->clipEnabled = 0;
    params->clipNormalX = params->clipNormalY = params->clipNormalZ = 0;
    params->clipLow = params->clipHigh = 0;
    if (!enabled || voxelToPatient == NULL) return;
    if (lowMm > highMm) { double t = lowMm; lowMm = highMm; highMm = t; }
    const double *m = voxelToPatient;
    // axis . (M v + T) = (axis . column0) vx + (axis . column1) vy + (axis . column2) vz + axis . T
    double nx = axis.x * m[0] + axis.y * m[1] + axis.z * m[2];
    double ny = axis.x * m[4] + axis.y * m[5] + axis.z * m[6];
    double nz = axis.x * m[8] + axis.y * m[9] + axis.z * m[10];
    double offset = axis.x * m[12] + axis.y * m[13] + axis.z * m[14];
    params->clipNormalX = (float)nx;
    params->clipNormalY = (float)ny;
    params->clipNormalZ = (float)nz;
    params->clipLow = (float)(lowMm - offset);
    params->clipHigh = (float)(highMm - offset);
    params->clipEnabled = 1;
}
