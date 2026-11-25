// BorosKitRender: slab pictures of scans too big for one GPU 3D texture (bricks), plain C.
// See include/BKSlabBrickCore.h for what it does, the rules and the porting notes.
// Boros 6 (2026-11-24, mpr-colour).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKSlabBrickCore.h"
#include <math.h>
#include <string.h>

// What: rule 1 along one axis: the number of bricks and their split points (n + 1 values in split).
// Returns n (0 for bad input). split may be NULL to only count.
static int32_t BKSlabBrickSplitAxis(int32_t d, int32_t maxSide, int32_t margin, int32_t *split)
{
    if (d < 1) return 0;
    if (d <= maxSide) {
        if (split) { split[0] = 0; split[1] = d - 1; }
        return 1;
    }
    int32_t usable = maxSide - 1 - 2 * margin;   // largest core length (voxel steps) that fits with its margins
    if (usable < 1) return 0;
    int32_t n = (int32_t)((d - 1 + usable - 1) / usable);   // ceil((d - 1) / usable)
    if (split)
        for (int32_t b = 0; b <= n; b++)
            split[b] = (int32_t)floor((double)b * (double)(d - 1) / (double)n + 0.5);
    return n;
}

int32_t BKSlabBrickPlan(const int32_t dims[3], int32_t maxSide, int32_t margin, BKSlabBrick *out, int32_t capacity,
                        int32_t gridCounts[3])
{
    if (dims == NULL || margin < 0 || maxSide <= 1 + 2 * margin) return 0;
    int32_t n[3];
    for (int a = 0; a < 3; a++) {
        n[a] = BKSlabBrickSplitAxis(dims[a], maxSide, margin, NULL);
        if (n[a] <= 0) return 0;
    }
    if (gridCounts) { gridCounts[0] = n[0]; gridCounts[1] = n[1]; gridCounts[2] = n[2]; }
    int64_t total = (int64_t)n[0] * n[1] * n[2];
    if (total > 0x7fffffff) return 0;
    if (out == NULL || capacity <= 0) return (int32_t)total;

    // Split points of each axis. Limit: at most BK_SLAB_BRICK_MAX_PER_AXIS bricks along one axis (with
    // maxSide 256 that is a side of about 15,800 voxels) - more returns 0 (the caller logs it).
    int32_t split[3][BK_SLAB_BRICK_MAX_PER_AXIS + 1];
    for (int a = 0; a < 3; a++) {
        if (n[a] > BK_SLAB_BRICK_MAX_PER_AXIS) return 0;
        BKSlabBrickSplitAxis(dims[a], maxSide, margin, split[a]);
    }
    int32_t count = 0;
    for (int32_t z = 0; z < n[2]; z++)
        for (int32_t y = 0; y < n[1]; y++)
            for (int32_t x = 0; x < n[0]; x++) {
                if (count >= capacity) return (int32_t)total;
                BKSlabBrick *b = &out[count++];
                int32_t g[3] = { x, y, z };
                for (int a = 0; a < 3; a++) {
                    b->grid[a] = g[a];
                    b->coreLo[a] = split[a][g[a]];
                    b->coreHi[a] = split[a][g[a] + 1];
                    int32_t lo = b->coreLo[a] - (n[a] > 1 ? margin : 0);
                    int32_t hi = b->coreHi[a] + (n[a] > 1 ? margin : 0);
                    b->texLo[a] = lo < 0 ? 0 : lo;
                    b->texHi[a] = hi > dims[a] - 1 ? dims[a] - 1 : hi;
                }
            }
    return (int32_t)total;
}

void BKSlabBrickPatientToVoxel(const double scanPatientToVoxel[16], const BKSlabBrick *brick, double out[16])
{
    if (scanPatientToVoxel == NULL || brick == NULL || out == NULL) return;
    memcpy(out, scanPatientToVoxel, 16 * sizeof(double));
    out[12] -= (double)brick->texLo[0];
    out[13] -= (double)brick->texLo[1];
    out[14] -= (double)brick->texLo[2];
}

void BKSlabBrickCoreBoxInTexture(const BKSlabBrick *brick, double lo[3], double hi[3])
{
    if (brick == NULL || lo == NULL || hi == NULL) return;
    for (int a = 0; a < 3; a++) {
        lo[a] = (double)(brick->coreLo[a] - brick->texLo[a]);
        hi[a] = (double)(brick->coreHi[a] - brick->texLo[a]);
    }
}

// What: the 3 x 3 part of m (column by column) applied to v.
static BKVec3d BKSlabBrickLinear(const double m[16], BKVec3d v)
{
    return BKV3d(m[0] * v.x + m[4] * v.y + m[8] * v.z, m[1] * v.x + m[5] * v.y + m[9] * v.z, m[2] * v.x + m[6] * v.y + m[10] * v.z);
}

double BKSlabBrickRayWeights(const double scanPatientToVoxel[16], const BKSlabBrick *brick, BKVec3d pixel0,
                             BKVec3d right, BKVec3d down, double spacing, double thickness,
                             int32_t width, int32_t height, float *weights)
{
    if (scanPatientToVoxel == NULL || brick == NULL || weights == NULL || width <= 0 || height <= 0 ||
        !(spacing > 0) || !isfinite(spacing) || !(thickness >= 0) || !isfinite(thickness))
        return -1;
    double rl = BKV3dLength(right), dl = BKV3dLength(down);
    if (!(rl > 0) || !(dl > 0)) return -1;
    right = BKV3dDiv(right, rl);
    down = BKV3dDiv(down, dl);
    BKVec3d dir = BKV3dCross(right, down);
    double dirLength = BKV3dLength(dir);
    if (!(dirLength > 0)) return -1;
    dir = BKV3dDiv(dir, dirLength);

    // Everything in the scan's voxel space: ov(x, y) = o0 + x * ax + y * ay, ray direction dv.
    BKVec3d o0 = BKV3dAdd(BKSlabBrickLinear(scanPatientToVoxel, pixel0),
                          BKV3d(scanPatientToVoxel[12], scanPatientToVoxel[13], scanPatientToVoxel[14]));
    BKVec3d ax = BKSlabBrickLinear(scanPatientToVoxel, BKV3dScale(right, spacing));
    BKVec3d ay = BKSlabBrickLinear(scanPatientToVoxel, BKV3dScale(down, spacing));
    BKVec3d dv = BKSlabBrickLinear(scanPatientToVoxel, dir);
    double lo[3] = { brick->coreLo[0], brick->coreLo[1], brick->coreLo[2] };
    double hi[3] = { brick->coreHi[0], brick->coreHi[1], brick->coreHi[2] };
    double half = 0.5 * thickness;
    const double tolerance = 1e-6;   // voxels: a point on a core face counts as inside (thickness 0)
    double largest = 0;

    for (int32_t y = 0; y < height; y++) {
        for (int32_t x = 0; x < width; x++) {
            BKVec3d ov = BKV3dAdd(o0, BKV3dAdd(BKV3dScale(ax, (double)x), BKV3dScale(ay, (double)y)));
            double w = 0;
            if (thickness == 0) {
                int inside = 1;
                for (int a = 0; a < 3 && inside; a++) {
                    double c = BKV3dComponent(ov, a);
                    if (!(c >= lo[a] - tolerance && c <= hi[a] + tolerance)) inside = 0;
                }
                w = inside ? 1 : 0;
            } else {
                double t0 = -half, t1 = half;
                for (int a = 0; a < 3 && t1 >= t0; a++) {
                    double o = BKV3dComponent(ov, a), d = BKV3dComponent(dv, a);
                    if (fabs(d) < 1e-15) {
                        if (!(o >= lo[a] && o <= hi[a])) t1 = t0 - 1;   // parallel to this face pair and outside
                    } else {
                        double ta = (lo[a] - o) / d, tb = (hi[a] - o) / d;
                        if (ta > tb) { double s = ta; ta = tb; tb = s; }
                        if (ta > t0) t0 = ta;
                        if (tb < t1) t1 = tb;
                    }
                }
                w = t1 > t0 ? t1 - t0 : 0;
            }
            weights[(size_t)y * (size_t)width + (size_t)x] = (float)w;
            if (w > largest) largest = w;
        }
    }
    return largest;
}

int BKSlabBrickVisitOrder(const BKSlabBrick *bricks, int32_t count, BKVec3d voxelDirection, int32_t *order)
{
    if (bricks == NULL || order == NULL || count <= 0) return 0;
    int32_t sign[3] = { voxelDirection.x < 0 ? -1 : 1, voxelDirection.y < 0 ? -1 : 1, voxelDirection.z < 0 ? -1 : 1 };
    for (int32_t i = 0; i < count; i++) order[i] = i;
    // Insertion sort on the key (z, y, x), each grid index taken in the ray's direction (stable, deterministic).
    for (int32_t i = 1; i < count; i++) {
        int32_t v = order[i];
        int32_t j = i - 1;
        while (j >= 0) {
            const BKSlabBrick *a = &bricks[order[j]], *b = &bricks[v];
            int greater = 0;
            for (int axis = 2; axis >= 0; axis--) {
                int32_t ka = a->grid[axis] * sign[axis], kb = b->grid[axis] * sign[axis];
                if (ka != kb) { greater = ka > kb; break; }
            }
            if (!greater) break;
            order[j + 1] = order[j];
            j--;
        }
        order[j + 1] = v;
    }
    return 1;
}

// ---- values ----------------------------------------------------------------------------------------------------

void BKSlabBrickBeginValues(int32_t mode, size_t count, float *acc, float *weightSum)
{
    if (acc == NULL || weightSum == NULL) return;
    float start = mode == 1 ? -INFINITY : (mode == 2 ? INFINITY : 0.0f);
    for (size_t i = 0; i < count; i++) { acc[i] = start; weightSum[i] = 0; }
}

void BKSlabBrickAddValues(int32_t mode, const float *values, const float *weights, size_t count, float *acc, float *weightSum)
{
    if (values == NULL || weights == NULL || acc == NULL || weightSum == NULL) return;
    for (size_t i = 0; i < count; i++) {
        float w = weights[i];
        if (!(w > 0)) continue;
        float v = values[i];
        if (mode == 1) { if (v > acc[i]) acc[i] = v; }
        else if (mode == 2) { if (v < acc[i]) acc[i] = v; }
        else acc[i] += v * w;
        weightSum[i] += w;
    }
}

void BKSlabBrickFinishValues(int32_t mode, const float *acc, const float *weightSum, size_t count, float outside, float *out)
{
    if (acc == NULL || weightSum == NULL || out == NULL) return;
    for (size_t i = 0; i < count; i++) {
        if (!(weightSum[i] > 0)) out[i] = outside;
        else out[i] = (mode == 1 || mode == 2) ? acc[i] : acc[i] / weightSum[i];
    }
}

// ---- colour channels -------------------------------------------------------------------------------------------

void BKSlabBrickBeginChannels(int32_t mode, size_t count, float *acc3, float *weightSum)
{
    if (acc3 == NULL || weightSum == NULL) return;
    float start = mode == 1 ? -INFINITY : (mode == 2 ? INFINITY : 0.0f);
    for (size_t i = 0; i < count; i++) {
        acc3[3 * i] = acc3[3 * i + 1] = acc3[3 * i + 2] = start;
        weightSum[i] = 0;
    }
}

void BKSlabBrickAddChannels(int32_t mode, const uint8_t *rgba, const float *weights, size_t count, float *acc3, float *weightSum)
{
    if (rgba == NULL || weights == NULL || acc3 == NULL || weightSum == NULL) return;
    for (size_t i = 0; i < count; i++) {
        float w = weights[i];
        if (!(w > 0)) continue;
        for (int c = 0; c < 3; c++) {
            float v = (float)rgba[4 * i + c];
            float *a = &acc3[3 * i + c];
            if (mode == 1) { if (v > *a) *a = v; }
            else if (mode == 2) { if (v < *a) *a = v; }
            else *a += v * w;
        }
        weightSum[i] += w;
    }
}

void BKSlabBrickFinishChannels(int32_t mode, const float *acc3, const float *weightSum, size_t count, uint8_t *outRGBA)
{
    if (acc3 == NULL || weightSum == NULL || outRGBA == NULL) return;
    for (size_t i = 0; i < count; i++) {
        for (int c = 0; c < 3; c++) {
            float v = 0;
            if (weightSum[i] > 0) v = (mode == 1 || mode == 2) ? acc3[3 * i + c] : acc3[3 * i + c] / weightSum[i];
            if (!(v > 0)) v = 0;
            if (v > 255) v = 255;
            outRGBA[4 * i + c] = (uint8_t)(v + 0.5f);
        }
        outRGBA[4 * i + 3] = 255;
    }
}

// ---- VR colour (over) ------------------------------------------------------------------------------------------

void BKSlabBrickBeginOver(size_t count, float *acc4)
{
    if (acc4 == NULL) return;
    memset(acc4, 0, count * 4 * sizeof(float));
}

void BKSlabBrickAddOver(const uint8_t *rgba, size_t count, float *acc4)
{
    if (rgba == NULL || acc4 == NULL) return;
    const float k = 1.0f / 255.0f;
    for (size_t i = 0; i < count; i++) {
        float *a = &acc4[4 * i];
        float remain = 1.0f - a[3];
        if (!(remain > 0)) continue;
        a[0] += remain * rgba[4 * i] * k;
        a[1] += remain * rgba[4 * i + 1] * k;
        a[2] += remain * rgba[4 * i + 2] * k;
        a[3] += remain * rgba[4 * i + 3] * k;
    }
}

void BKSlabBrickFinishOver(const float *acc4, size_t count, uint8_t *outRGBA)
{
    if (acc4 == NULL || outRGBA == NULL) return;
    for (size_t i = 0; i < 4 * count; i++) {
        float v = acc4[i];
        if (!(v > 0)) v = 0;
        if (v > 1) v = 1;
        outRGBA[i] = (uint8_t)(v * 255.0f + 0.5f);
    }
}
