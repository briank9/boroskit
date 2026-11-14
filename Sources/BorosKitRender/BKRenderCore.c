// BorosKitRender: BKRenderCore implementation (see include/BKRenderCore.h).
// Original BorosKit code written for this project; contains no third-party code.
//
// The transfer-function and storage code below was moved here unchanged (same arithmetic,
// same order of operations) from BKTransferFunction.m, BKVolumeRenderer.m and
// BKVolumeTexture.m, so the GPU receives exactly the same numbers as before.

#include "BKRenderCore.h"

#include <math.h>

void BKRenderTFEvaluate(const BKRenderTFPoint *p, size_t count, float value, float *out, int components)
{
    if (count == 0) return;
    if (value <= p[0].value) { for (int k = 0; k < components; k++) out[k] = p[0].c[k]; return; }
    if (value >= p[count - 1].value) { for (int k = 0; k < components; k++) out[k] = p[count - 1].c[k]; return; }
    size_t i = 1;
    while (p[i].value < value) i++;
    float t = (value - p[i - 1].value) / (p[i].value - p[i - 1].value);
    for (int k = 0; k < components; k++) out[k] = p[i - 1].c[k] + t * (p[i].c[k] - p[i - 1].c[k]);
}

void BKRenderTFGetRGBA(const BKRenderTFPoint *color, size_t colorCount,
                       const BKRenderTFPoint *opacity, size_t opacityCount, float value, float rgba[4])
{
    rgba[0] = rgba[1] = rgba[2] = rgba[3] = 1.0f;
    BKRenderTFEvaluate(color, colorCount, value, rgba, 3);
    BKRenderTFEvaluate(opacity, opacityCount, value, rgba + 3, 1);
}

float BKRenderTFMinimumValue(const BKRenderTFPoint *color, size_t colorCount,
                             const BKRenderTFPoint *opacity, size_t opacityCount)
{
    float m = INFINITY;
    if (colorCount) m = fminf(m, color[0].value);
    if (opacityCount) m = fminf(m, opacity[0].value);
    return isinf(m) ? 0 : m;
}

float BKRenderTFMaximumValue(const BKRenderTFPoint *color, size_t colorCount,
                             const BKRenderTFPoint *opacity, size_t opacityCount)
{
    float m = -INFINITY;
    if (colorCount) m = fmaxf(m, color[colorCount - 1].value);
    if (opacityCount) m = fmaxf(m, opacity[opacityCount - 1].value);
    return isinf(m) ? 0 : m;
}

void BKRenderTFBake(const BKRenderTFPoint *color, size_t colorCount,
                    const BKRenderTFPoint *opacity, size_t opacityCount, float *rgba, size_t count)
{
    float lo = BKRenderTFMinimumValue(color, colorCount, opacity, opacityCount);
    float hi = BKRenderTFMaximumValue(color, colorCount, opacity, opacityCount);
    for (size_t i = 0; i < count; i++) {
        float value = count > 1 ? lo + (hi - lo) * (float)i / (float)(count - 1) : lo;
        BKRenderTFGetRGBA(color, colorCount, opacity, opacityCount, value, rgba + 4 * i);
    }
}

void BKRenderAlphaPrefixCount(const float *rgba, size_t entries, uint32_t *counts)
{
    counts[0] = 0;
    for (size_t i = 0; i < entries; i++)
        counts[i + 1] = counts[i] + (rgba[4 * i + 3] > 0.0f ? 1 : 0);
}

void BKRenderBrickGrid(uint32_t width, uint32_t height, uint32_t depth, uint32_t brickSize, uint32_t grid[3])
{
    grid[0] = (width + brickSize - 1) / brickSize;
    grid[1] = (height + brickSize - 1) / brickSize;
    grid[2] = (depth + brickSize - 1) / brickSize;
}

BKRenderQuantization BKRenderQuantizationForRange(float lo, float hi, int integral)
{
    BKRenderQuantization q;
    float range = hi - lo;
    q.step = range > 0 ? range / 65535.0f : 1.0f;
    q.lossless = range == 0 || (integral && range <= 65535.0f);
    q.valueOffset = lo;
    q.valueScale = q.step * 65535.0f;   // texel 0..1 -> 0..65535 steps -> real value
    return q;
}

int BKRenderAllIntegral(const float *values, size_t count)
{
    for (size_t i = 0; i < count; i++)
        if (values[i] != floorf(values[i])) return 0;
    return 1;
}

void BKRenderQuantizeToSteps(const float *values, size_t count, BKRenderQuantization q, uint16_t *steps)
{
    const float negOffset = -q.valueOffset, invStep = 1.0f / q.step;
    for (size_t i = 0; i < count; i++) {
        // Two separate roundings, like the vDSP add-then-multiply in BKVolumeTexture.m.
        float shifted = values[i] + negOffset;
        float s = shifted * invStep;
        if (!(s >= 0.0f)) s = 0.0f;          // also catches NaN
        if (s > 65535.0f) s = 65535.0f;
        steps[i] = (uint16_t)rintf(s);       // nearest, ties to even
    }
}
