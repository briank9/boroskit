// BorosKitRender: scan placement for the MPR / curved-MPR slab pictures (plain C).
// See include/BKSlabScanCore.h for what it does, the rules and the porting notes.
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabScanCore.h"
#include <math.h>
#include <string.h>

// What: a positive finite number?
static int BKSlabScanPositive(double x) { return x > 0 && isfinite(x); }

// What: inverts the affine matrix m (column by column, last row 0 0 0 1). Returns 0 when its 3 x 3 part is singular.
static int BKSlabScanInvertAffine(const double m[16], double out[16])
{
    // 3 x 3 part: a[row][col] = m[col * 4 + row]
    double a00 = m[0], a10 = m[1], a20 = m[2];
    double a01 = m[4], a11 = m[5], a21 = m[6];
    double a02 = m[8], a12 = m[9], a22 = m[10];
    double c00 = a11 * a22 - a12 * a21, c01 = a02 * a21 - a01 * a22, c02 = a01 * a12 - a02 * a11;
    double c10 = a12 * a20 - a10 * a22, c11 = a00 * a22 - a02 * a20, c12 = a02 * a10 - a00 * a12;
    double c20 = a10 * a21 - a11 * a20, c21 = a01 * a20 - a00 * a21, c22 = a00 * a11 - a01 * a10;
    double det = a00 * c00 + a01 * c10 + a02 * c20;
    if (!(fabs(det) > 1e-300) || !isfinite(det)) return 0;
    double inv[3][3] = { { c00 / det, c01 / det, c02 / det },
                         { c10 / det, c11 / det, c12 / det },
                         { c20 / det, c21 / det, c22 / det } };   // inv[row][col]
    double t[3] = { m[12], m[13], m[14] };
    memset(out, 0, 16 * sizeof(double));
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) out[c * 4 + r] = inv[r][c];
        out[12 + r] = -(inv[r][0] * t[0] + inv[r][1] * t[1] + inv[r][2] * t[2]);
    }
    out[15] = 1;
    return 1;
}

int BKSlabScanMake(const BKSlabScanInput *in, BKSlabScan *out)
{
    if (in == NULL || out == NULL) return 0;
    memset(out, 0, sizeof(*out));

    // Rule 1: pixel spacing.
    double sx = in->pixelSpacingX, sy = in->pixelSpacingY;
    if (!BKSlabScanPositive(sx)) { sx = 1; out->flags |= BKSlabScanUsedDefaultPixelSpacing; }
    if (!BKSlabScanPositive(sy)) { sy = 1; out->flags |= BKSlabScanUsedDefaultPixelSpacing; }

    // Rule 2: slice step (sign kept).
    double step = in->sliceInterval;
    if (step == 0 || !isfinite(step)) {
        step = in->sliceThickness;
        out->flags |= BKSlabScanUsedSliceThickness;
        if (step == 0 || !isfinite(step)) {
            step = 0.5 * (sx + sy);
            out->flags &= ~(uint32_t)BKSlabScanUsedSliceThickness;
            out->flags |= BKSlabScanUsedAverageSpacing;
        }
    }
    if (step < 0) out->flags |= BKSlabScanSlicesBackwards;

    // Rule 3: orientation.
    BKVec3d row = BKV3d(in->cosines[0], in->cosines[1], in->cosines[2]);
    BKVec3d col = BKV3d(in->cosines[3], in->cosines[4], in->cosines[5]);
    BKVec3d nrm = BKV3d(in->cosines[6], in->cosines[7], in->cosines[8]);
    double det = BKV3dDot(row, BKV3dCross(col, nrm));
    if (!isfinite(det) || !(fabs(det) >= 1e-6)) {
        row = BKV3d(1, 0, 0); col = BKV3d(0, 1, 0); nrm = BKV3d(0, 0, 1);
        out->flags |= BKSlabScanUsedIdentityOrientation;
    }

    // Rule 4: placement.
    BKVec3d origin = BKV3d(in->origin[0], in->origin[1], in->origin[2]);
    if (!isfinite(origin.x) || !isfinite(origin.y) || !isfinite(origin.z)) origin = BKV3d(0, 0, 0);
    out->origin = origin;
    out->axes[0] = row;
    out->axes[1] = col;
    out->axes[2] = step < 0 ? BKV3dNeg(nrm) : nrm;
    out->spacing = BKV3d(sx, sy, fabs(step));
    out->sliceStep = step;
    out->minSpacing = fmin(fmin(sx, sy), fabs(step));

    double *v = out->voxelToPatient;
    BKVec3d ci = BKV3dScale(row, sx), cj = BKV3dScale(col, sy), ck = BKV3dScale(nrm, step);
    v[0] = ci.x; v[1] = ci.y; v[2] = ci.z; v[3] = 0;
    v[4] = cj.x; v[5] = cj.y; v[6] = cj.z; v[7] = 0;
    v[8] = ck.x; v[9] = ck.y; v[10] = ck.z; v[11] = 0;
    v[12] = origin.x; v[13] = origin.y; v[14] = origin.z; v[15] = 1;
    return BKSlabScanInvertAffine(v, out->patientToVoxel);
}

// What: the matrix m (column by column) applied to the point p (w = 1).
static BKVec3d BKSlabScanApply(const double m[16], BKVec3d p)
{
    return BKV3d(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                 m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                 m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]);
}

BKVec3d BKSlabScanVoxelToPatient(const BKSlabScan *scan, BKVec3d voxel)
{
    if (scan == NULL) return voxel;
    return BKSlabScanApply(scan->voxelToPatient, voxel);
}

BKVec3d BKSlabScanPatientToVoxel(const BKSlabScan *scan, BKVec3d p)
{
    if (scan == NULL) return p;
    return BKSlabScanApply(scan->patientToVoxel, p);
}

BKSlabScanVolumicStatus BKSlabScanCheckVolumic(int32_t sliceCount, const int32_t *widths, const int32_t *heights)
{
    if (sliceCount < 3) return BKSlabScanTooFewSlices;
    if (widths == NULL || heights == NULL) return BKSlabScanVolumic;
    for (int32_t i = 0; i < sliceCount; i++) {
        if (widths[i] <= 0 || heights[i] <= 0) return BKSlabScanEmptySlices;
        if (widths[i] != widths[0] || heights[i] != heights[0]) return BKSlabScanUnequalSlices;
    }
    return BKSlabScanVolumic;
}
