// BorosKitDICOM: BKDicomSeriesCore - see BKDicomSeriesCore.h.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKDicomSeriesCore.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
    double distance;          // along the normal
    int32_t instance;
    uint32_t input;           // index into the caller's slices
} BKSortKey;

static int BKCompareKeys(const void *a, const void *b)
{
    const BKSortKey *x = (const BKSortKey *)a, *y = (const BKSortKey *)b;
    if (x->distance < y->distance) return -1;
    if (x->distance > y->distance) return 1;
    if (x->instance < y->instance) return -1;
    if (x->instance > y->instance) return 1;
    return x->input < y->input ? -1 : (x->input > y->input ? 1 : 0);
}

static int BKCompareDoubles(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

int BKDicomSeriesSort(const BKDicomSlice *slices, uint32_t count, double fallbackSpacing, BKDicomSeriesOrder *result)
{
    memset(result, 0, sizeof(*result));
    if (slices == NULL || count == 0) return 0;
    if (!(fallbackSpacing > 0)) fallbackSpacing = 1.0;
    BKSortKey *keys = (BKSortKey *)malloc(sizeof(BKSortKey) * count);
    result->order = (uint32_t *)malloc(sizeof(uint32_t) * count);
    if (!keys || !result->order) { free(keys); free(result->order); result->order = NULL; return 0; }

    // The reference orientation is the first slice with geometry; every slice must be parallel to it.
    int32_t reference = -1;
    for (uint32_t i = 0; i < count; i++) if (slices[i].hasGeometry) { reference = (int32_t)i; break; }

    uint32_t n = 0;
    if (reference < 0) {
        // No geometry at all: instance-number order, assumed spacing along the default normal.
        for (uint32_t i = 0; i < count; i++) {
            keys[n].distance = 0; keys[n].instance = slices[i].instanceNumber; keys[n].input = i; n++;
        }
        qsort(keys, n, sizeof(BKSortKey), BKCompareKeys);
        for (uint32_t i = 0; i < n; i++) result->order[i] = slices[keys[i].input].sourceIndex;
        result->count = n;
        result->sliceSpacing = fallbackSpacing;
        result->sliceStep = BKV3d(0, 0, fallbackSpacing);
        if (count > 1) result->warnings |= BKSeriesWarningNoGeometry;
        free(keys);
        return 1;
    }

    const BKDicomSlice *ref = &slices[reference];
    BKVec3d normal = BKV3dNormalize(BKV3dCross(ref->rowDirection, ref->columnDirection));
    for (uint32_t i = 0; i < count; i++) {
        const BKDicomSlice *s = &slices[i];
        if (!s->hasGeometry) { result->dropped++; result->warnings |= BKSeriesWarningMixedOrientation; continue; }
        // Parallel within ~0.5 degree (cosines within 1e-4 of each other).
        if (fabs(BKV3dDot(s->rowDirection, ref->rowDirection) - 1.0) > 1e-4 ||
            fabs(BKV3dDot(s->columnDirection, ref->columnDirection) - 1.0) > 1e-4) {
            result->dropped++;
            result->warnings |= BKSeriesWarningMixedOrientation;
            continue;
        }
        keys[n].distance = BKV3dDot(s->position, normal);
        keys[n].instance = s->instanceNumber;
        keys[n].input = i;
        n++;
    }
    qsort(keys, n, sizeof(BKSortKey), BKCompareKeys);

    // Drop slices that repeat a position (within 0.001 mm), keeping the first in order.
    uint32_t kept = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (kept > 0) {
            BKVec3d a = slices[keys[kept - 1].input].position, b = slices[keys[i].input].position;
            if (BKV3dDistance(a, b) < 1e-3) { result->dropped++; result->warnings |= BKSeriesWarningDuplicates; continue; }
        }
        keys[kept++] = keys[i];
    }
    for (uint32_t i = 0; i < kept; i++) result->order[i] = slices[keys[i].input].sourceIndex;
    result->count = kept;

    if (kept < 2) {
        result->sliceSpacing = fallbackSpacing;
        result->sliceStep = BKV3dScale(normal, fallbackSpacing);
        free(keys);
        return 1;
    }

    // Spacing: the median gap along the normal; uneven when any gap is >10% (and >0.1 mm) off it.
    double *gaps = (double *)malloc(sizeof(double) * (kept - 1));
    if (!gaps) { free(keys); free(result->order); result->order = NULL; return 0; }
    for (uint32_t i = 0; i + 1 < kept; i++) gaps[i] = keys[i + 1].distance - keys[i].distance;
    qsort(gaps, kept - 1, sizeof(double), BKCompareDoubles);
    double median = gaps[(kept - 1) / 2];
    double minGap = gaps[0], maxGap = gaps[kept - 2];
    free(gaps);
    double tolerance = fmax(0.1 * median, 0.1);
    if (maxGap - median > tolerance || median - minGap > tolerance) result->warnings |= BKSeriesWarningUneven;

    // The step between slices follows the real positions (first to last), so a tilted (sheared) stack keeps
    // its true geometry; evenly spaced stacks give exactly normal * spacing.
    BKVec3d first = slices[keys[0].input].position, last = slices[keys[kept - 1].input].position;
    BKVec3d step = BKV3dDiv(BKV3dSub(last, first), (double)(kept - 1));
    double along = BKV3dDot(step, normal);
    BKVec3d sideways = BKV3dSub(step, BKV3dScale(normal, along));
    if (BKV3dLength(sideways) > 1e-3 * fabs(along) + 1e-6) result->warnings |= BKSeriesWarningTilted;
    result->sliceStep = step;
    result->sliceSpacing = fabs(along);
    if (!(result->sliceSpacing > 0)) { result->sliceSpacing = fallbackSpacing; result->sliceStep = BKV3dScale(normal, fallbackSpacing); }
    free(keys);
    return 1;
}

void BKDicomVoxelToPatient(const BKDicomSlice *first, double columnSpacing, double rowSpacing, BKVec3d sliceStep, double out[16])
{
    BKVec3d x = BKV3dScale(first->rowDirection, columnSpacing);
    BKVec3d y = BKV3dScale(first->columnDirection, rowSpacing);
    double m[16] = {
        x.x, x.y, x.z, 0,
        y.x, y.y, y.z, 0,
        sliceStep.x, sliceStep.y, sliceStep.z, 0,
        first->position.x, first->position.y, first->position.z, 1,
    };
    memcpy(out, m, sizeof(m));
}

int BKDicomInvertAffine(const double m[16], double out[16])
{
    // 3x3 part a[r][c] = m[c * 4 + r]
    double a00 = m[0], a10 = m[1], a20 = m[2];
    double a01 = m[4], a11 = m[5], a21 = m[6];
    double a02 = m[8], a12 = m[9], a22 = m[10];
    double c00 = a11 * a22 - a12 * a21, c01 = a02 * a21 - a01 * a22, c02 = a01 * a12 - a02 * a11;
    double c10 = a12 * a20 - a10 * a22, c11 = a00 * a22 - a02 * a20, c12 = a02 * a10 - a00 * a12;
    double c20 = a10 * a21 - a11 * a20, c21 = a01 * a20 - a00 * a21, c22 = a00 * a11 - a01 * a10;
    double det = a00 * c00 + a01 * c10 + a02 * c20;
    if (!(fabs(det) > 1e-300) || !isfinite(det)) return 0;
    double inv = 1.0 / det;
    double b[3][3] = { { c00 * inv, c01 * inv, c02 * inv }, { c10 * inv, c11 * inv, c12 * inv }, { c20 * inv, c21 * inv, c22 * inv } };
    double t[3] = { m[12], m[13], m[14] };
    for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) out[c * 4 + r] = b[r][c];
    for (int r = 0; r < 3; r++) out[12 + r] = -(b[r][0] * t[0] + b[r][1] * t[1] + b[r][2] * t[2]);
    out[3] = out[7] = out[11] = 0;
    out[15] = 1;
    return 1;
}

void BKDicomOrientationLetters(BKVec3d d, double minimum, char letters[4])
{
    double v[3] = { d.x, d.y, d.z };
    const char positive[3] = { 'L', 'P', 'H' }, negative[3] = { 'R', 'A', 'F' };
    int order[3] = { 0, 1, 2 };
    // Strongest axis first (stable: ties keep x, y, z order).
    for (int i = 0; i < 3; i++)
        for (int j = i + 1; j < 3; j++)
            if (fabs(v[order[j]]) > fabs(v[order[i]])) { int t = order[i]; order[i] = order[j]; order[j] = t; }
    int n = 0;
    for (int i = 0; i < 3; i++) {
        double c = v[order[i]];
        if (fabs(c) < minimum) continue;
        letters[n++] = c > 0 ? positive[order[i]] : negative[order[i]];
    }
    letters[n] = 0;
}
