// BorosKitRender: BKVolumeRayCore - see BKVolumeRayCore.h (plain C99; VULKAN: safe to translate directly).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKVolumeRayCore.h"
#include <math.h>
#include <float.h>

double BKRayOpacityAt(const BKRayOpacityTable *table, double value)
{
    if (table == 0 || table->opacity == 0 || table->count <= 0) return 1.0;
    if (table->count == 1 || !(table->maxValue > table->minValue)) return table->opacity[0];
    double t = (value - table->minValue) / (table->maxValue - table->minValue) * (double)(table->count - 1);
    long i = lround(t);
    if (i < 0) i = 0;
    if (i > table->count - 1) i = table->count - 1;
    return table->opacity[i];
}

// patient mm -> voxel index (column-by-column matrix).
static void ToVoxel(const double m[16], const double p[3], double out[3])
{
    for (int r = 0; r < 3; r++)
        out[r] = m[0 * 4 + r] * p[0] + m[1 * 4 + r] * p[1] + m[2 * 4 + r] * p[2] + m[3 * 4 + r];
}

int BKVolumeRayFirstHit(const BKRayVolume *volume, const double start[3], const double end[3], double stepMM,
                        const BKRayOpacityTable *table, int32_t mode, double threshold, double minValue,
                        const float *hiddenPlanes, int32_t planeCount, BKRayHit *hit)
{
    if (volume == 0 || volume->voxels == 0 || hit == 0 || !(stepMM > 0)) return 0;
    if (volume->width <= 0 || volume->height <= 0 || volume->depth <= 0) return 0;
    double d[3] = { end[0] - start[0], end[1] - start[1], end[2] - start[2] };
    double length = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (!(length > 0)) return 0;
    long steps = (long)ceil(length / stepMM);
    if (steps > 200000) steps = 200000;   // safety: a very long ray with a tiny step
    double sum = 0, best = -DBL_MAX;
    int found = 0;
    for (long s = 0; s <= steps; s++) {
        double t = (double)s / (double)steps;
        double p[3] = { start[0] + d[0] * t, start[1] + d[1] * t, start[2] + d[2] * t };
        int hidden = 0;
        for (int32_t k = 0; k < planeCount && !hidden; k++) {
            const float *pl = hiddenPlanes + 4 * k;
            hidden = pl[0] * p[0] + pl[1] * p[1] + pl[2] * p[2] + pl[3] > 0.0;
        }
        if (hidden) continue;
        double v[3];
        ToVoxel(volume->patientToVoxel, p, v);
        long x = lround(v[0]), y = lround(v[1]), z = lround(v[2]);
        if (x < 0 || y < 0 || z < 0 || x >= volume->width || y >= volume->height || z >= volume->depth) continue;
        float value = volume->voxels[(size_t)z * (size_t)volume->width * (size_t)volume->height + (size_t)y * (size_t)volume->width + (size_t)x];
        int candidate = 0;
        if (mode == BKRayModeMaximum) {
            if (value > best && (minValue == 0 || value >= minValue)) { best = value; candidate = 1; }
        } else {
            sum += BKRayOpacityAt(table, value);
            candidate = sum >= threshold && (minValue == 0 || value >= minValue);
        }
        if (candidate) {
            hit->patient[0] = p[0]; hit->patient[1] = p[1]; hit->patient[2] = p[2];
            hit->voxel[0] = (int32_t)x; hit->voxel[1] = (int32_t)y; hit->voxel[2] = (int32_t)z;
            hit->value = value;
            found = 1;
            if (mode != BKRayModeMaximum) return 1;
        }
    }
    return found;
}
