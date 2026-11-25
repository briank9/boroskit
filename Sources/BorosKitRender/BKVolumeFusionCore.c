// BorosKitRender: BKVolumeFusionCore - see BKVolumeFusionCore.h (plain C99; VULKAN: safe to translate directly).
// Boros 6 (2026-11-24, vr-colour-fusion).
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKVolumeFusionCore.h"
#include <math.h>

int32_t BKFusionBlendProjection(int32_t mainMode)
{
    if (mainMode == 1) return BKFusionProjectionMaximum;
    if (mainMode == 2 || mainMode == 3) return BKFusionProjectionMinimum;
    return BKFusionProjectionComposite;
}

void BKFusionBlendOpacityTable(float blendFactor, int32_t maximumIntensity, float out[256])
{
    for (int i = 0; i < 256; i++) {
        float v = maximumIntensity ? (2.0f * blendFactor * (float)i) / 256.0f
                                   : (blendFactor / 3.0f * (float)i) / 256.0f - 8.0f;
        if (v > 255.0f) v = 255.0f;
        if (v < 0.0f) v = 0.0f;
        out[i] = v / 255.0f;
    }
}

float BKFusionBlendOpacityUnitDistance(float superSampling)
{
    return superSampling > 0 ? 1.0f / superSampling : 1.0f;
}

float BKFusionTableEntryValue(float low, float high, int32_t index)
{
    return low + (high - low) * (float)index / 254.0f;
}

void BKFusionTableLookup(const float *rgba, int32_t entries, float tableMin, float tableMax, float value, float out[4])
{
    out[0] = out[1] = out[2] = out[3] = 0;
    if (rgba == 0 || entries <= 0) return;
    float range = tableMax - tableMin;
    if (!(range > 1e-6f)) range = 1e-6f;   // same floor as the GPU (max(tfMax - tfMin, 1e-6))
    float x = (value - tableMin) / range;
    float n = (float)entries;
    float t = x * n - 0.5f;
    if (t < 0) t = 0;
    if (t > n - 1) t = n - 1;
    float i0 = floorf(t);
    float i1 = fminf(i0 + 1.0f, n - 1.0f);
    float f = t - i0;
    const float *c0 = rgba + 4 * (int32_t)i0, *c1 = rgba + 4 * (int32_t)i1;
    for (int k = 0; k < 4; k++) out[k] = c0[k] + (c1[k] - c0[k]) * f;
}

float BKFusionStepOpacity(float tableOpacity, float exponent)
{
    if (!(tableOpacity > 0.0f)) return 0.0f;
    return 1.0f - powf(1.0f - fminf(tableOpacity, 0.9999f), exponent);
}

void BKColorVoxelStep(const float rgb[3], const float *table, int32_t entries, float tableMin, float tableMax,
                      float exponent, int32_t useTableColours, float out[4])
{
    float premult[3] = { 0, 0, 0 }, alpha = 0;
    for (int c = 0; c < 3; c++) {
        float e[4];
        BKFusionTableLookup(table, entries, tableMin, tableMax, rgb[c], e);
        float a = BKFusionStepOpacity(e[3], exponent);
        if (!(a > 0)) continue;
        float colour[3] = { 0, 0, 0 };
        if (useTableColours) { colour[0] = e[0]; colour[1] = e[1]; colour[2] = e[2]; }
        else colour[c] = fminf(fmaxf(rgb[c] / 255.0f, 0.0f), 1.0f);
        for (int k = 0; k < 3; k++) premult[k] += a * colour[k];
        alpha += a;
    }
    if (alpha > 1.0f) alpha = 1.0f;
    for (int k = 0; k < 3; k++) out[k] = fminf(premult[k], alpha);
    out[3] = alpha;
}

void BKFusionMixSamples(const float a[4], const float b[4], float out[4])
{
    // A step without opacity leaves the other exactly as it is (no rounding through the formula below).
    if (!(b[3] > 0.0f)) { for (int k = 0; k < 4; k++) out[k] = a[3] > 0.0f ? a[k] : 0.0f; return; }
    if (!(a[3] > 0.0f)) { for (int k = 0; k < 4; k++) out[k] = b[k]; return; }
    float sum = a[3] + b[3];
    float alpha = 1.0f - (1.0f - a[3]) * (1.0f - b[3]);
    // Straight colour = (premultiplied a + premultiplied b) / (a.a + b.a); premultiplied again by the mixed opacity.
    float s = alpha / sum;
    for (int k = 0; k < 3; k++) out[k] = (a[k] + b[k]) * s;
    out[3] = alpha;
}

void BKFusionOverlay(const float over[4], const float under[3], float out[3])
{
    for (int k = 0; k < 3; k++) out[k] = over[k] + (1.0f - over[3]) * under[k];
}

int BKFusionRayBoxInterval(BKVec3d origin, BKVec3d dir, BKVec3d lo, BKVec3d hi, double tMin, double tMax,
                           double *t0, double *t1)
{
    double a = tMin, b = tMax;
    for (int k = 0; k < 3; k++) {
        double o = BKV3dComponent(origin, k), d = BKV3dComponent(dir, k);
        double l = BKV3dComponent(lo, k), h = BKV3dComponent(hi, k);
        if (d == 0.0) {
            if (o < l || o > h) return 0;   // parallel to this axis and outside the box's range
            continue;
        }
        double ta = (l - o) / d, tb = (h - o) / d;
        if (ta > tb) { double s = ta; ta = tb; tb = s; }
        if (ta > a) a = ta;
        if (tb < b) b = tb;
    }
    if (!(b >= a) || isinf(a) || isinf(b)) return 0;
    *t0 = a;
    *t1 = b;
    return 1;
}

int BKFusionUnionInterval(int hasA, double a0, double a1, int hasB, double b0, double b1, double *t0, double *t1)
{
    if (hasA && hasB) { *t0 = fmin(a0, b0); *t1 = fmax(a1, b1); return 1; }
    if (hasA) { *t0 = a0; *t1 = a1; return 1; }
    if (hasB) { *t0 = b0; *t1 = b1; return 1; }
    return 0;
}

void BKFusionWindowDrag(float startLevel, float startWidth, double dx, double dyDown, int32_t isPET, int32_t petMode,
                        float petMinimum, float *level, float *width)
{
    // Whole points, as the classic window counted the mouse move (it cut the fraction off).
    double ix = (double)(long)dx, iy = (double)(long)dyDown;
    float adapter = startWidth / 100.0f;
    float startMin = startLevel - startWidth / 2.0f, startMax = startLevel + startWidth / 2.0f;
    float wl = startLevel, ww = startWidth;
    if (isPET && petMode == 1) {
        float end = startMax + (float)(-iy) * adapter;
        ww = end - startMin;
        wl = ww / 2.0f + petMinimum;
        if (ww < 0.1f) ww = 0.1f;
        if (wl - ww / 2.0f < 0) wl = ww / 2.0f;
    } else if (isPET && petMode == 2) {
        float end = startMax - (float)iy * adapter;
        float start = startMin + (float)ix * adapter;
        if (start < 0) start = 0;
        wl = start + (end - start) / 2.0f;
        ww = end - start;
        if (ww < 0.1f) ww = 0.1f;
    } else {
        wl = startLevel - (float)iy * adapter;
        ww = startWidth + (float)ix * adapter;
        if (ww < 0.1f) ww = 0.1f;
    }
    *level = wl;
    *width = ww;
}
