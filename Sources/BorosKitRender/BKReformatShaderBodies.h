// BorosKitRender: BKReformatShaderBodies.h - the curved reformat (curved MPR / panorex) kernel written ONCE for Metal
// and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #5, shader option C): moved operation for operation
// from BKCurvedReformat.mm (only `(i ? a : b)` became `(i != 0 ? a : b)` and the weights array became an out
// parameter), so the Metal pictures stay bit-identical (golden strict). It mirrors BKCurvedReformatCore.c (the CPU
// reference) line by line, including BOTH height limits (the Mac band and the Boros Mobile clip band).
//
// PORTING NOTES:
//   - Only #defines, pasted into the Metal source (BKCurvedReformat.mm, BK stringify) and #included by GLSL
//     (Sources/BorosKitGPUVulkan/Shaders/bk_curved_reformat.comp). No // comments or # directives inside the macros.
//   - Shared subset: bk_float3 / bk_float4 / bk_int3; bkr_texture3d (parameter type), BKR_READ(t, x, y, z) (exact
//     texel .r); BKR_P_PARAM / BKR_P_ARG / BKR_P_FIRST_PARAM / BKR_P_FIRST_ARG (params block p); BKR_OUT4(name)
//     (an out float[4]); BKR_FN. Resources: vol, p, frames (float4 per entry, 3 per column), outValues.
//   - The kernel body uses gid (uint2 pixel) from its entry point.

#ifndef BK_REFORMAT_SHADER_BODIES_H
#define BK_REFORMAT_SHADER_BODIES_H

/* Exact voxel read or outOfBoundsValue outside the scan; Catmull-Rom weights; the sample (nearest / linear with the
 * classic outside rule / cubic) = BKReformatSample; the clip band test = BKReformatInBand. */
#define BK_REFORMAT_HELPER_BODIES \
BKR_FN float bkr_fetch(bkr_texture3d vol BKR_P_PARAM, int x, int y, int z) \
{ \
    if (x < 0 || y < 0 || z < 0 || x >= int(p.volumeWide) || y >= int(p.volumeHigh) || z >= int(p.volumeDeep)) \
        return p.outOfBoundsValue; \
    return BKR_READ(vol, x, y, z) * p.valueScale + p.valueOffset; \
} \
BKR_FN void bkr_cubic_weights(float d, BKR_OUT4(w)) \
{ \
    float d2 = d * d, d3 = d2 * d; \
    w[0] = 0.5f * (-d + 2.0f * d2 - d3); \
    w[1] = 0.5f * (2.0f - 5.0f * d2 + 3.0f * d3); \
    w[2] = 0.5f * (d + 4.0f * d2 - 3.0f * d3); \
    w[3] = 0.5f * (-d2 + d3); \
} \
BKR_FN float bkr_sample(bkr_texture3d vol BKR_P_PARAM, bk_float3 c) \
{ \
    if (p.interpolation == 0) { \
        return bkr_fetch(vol BKR_P_ARG, int(c.x + 0.5f), int(c.y + 0.5f), int(c.z + 0.5f)); \
    } \
    if (p.interpolation == 1) { \
        bk_int3 i0 = bk_int3(c); \
        if (i0.x < 0 || i0.y < 0 || i0.z < 0 || i0.x + 1 >= int(p.volumeWide) || i0.y + 1 >= int(p.volumeHigh) || \
            i0.z + 1 >= int(p.volumeDeep)) \
            return p.outOfBoundsValue; \
        bk_float3 d = c - bk_float3(i0); \
        float sum = 0.0f; \
        for (int k = 0; k < 2; k++) \
            for (int j = 0; j < 2; j++) \
                for (int i = 0; i < 2; i++) { \
                    float w = (i != 0 ? d.x : 1.0f - d.x) * (j != 0 ? d.y : 1.0f - d.y) * (k != 0 ? d.z : 1.0f - d.z); \
                    sum += w * bkr_fetch(vol BKR_P_ARG, i0.x + i, i0.y + j, i0.z + k); \
                } \
        return sum; \
    } \
    bk_float3 f = floor(c); \
    bk_float3 d = c - f; \
    bk_int3 i0 = bk_int3(f); \
    float wx[4], wy[4], wz[4]; \
    bkr_cubic_weights(d.x, wx); \
    bkr_cubic_weights(d.y, wy); \
    bkr_cubic_weights(d.z, wz); \
    float sum = 0.0f; \
    for (int k = 0; k < 4; k++) { \
        float plane = 0.0f; \
        for (int j = 0; j < 4; j++) { \
            float line = 0.0f; \
            for (int i = 0; i < 4; i++) line += wx[i] * bkr_fetch(vol BKR_P_ARG, i0.x + i - 1, i0.y + j - 1, i0.z + k - 1); \
            plane += wy[j] * line; \
        } \
        sum += wz[k] * plane; \
    } \
    return sum; \
} \
BKR_FN bool bkr_in_band(BKR_P_FIRST_PARAM bk_float3 c) \
{ \
    if (p.clipEnabled == 0) return true; \
    float t = p.clipNormalX * c.x + p.clipNormalY * c.y + p.clipNormalZ * c.z; \
    return t >= p.clipLow && t <= p.clipHigh; \
}

/* One thread per output pixel: walk the slab of column gid.x at row gid.y, keep the samples inside both height
 * limits (Mac band from the column's height function; clip band), and project them (first / MIP / MinIP / running
 * mean / radiograph). A pixel without samples: bandOutsideValue (band) or outOfBoundsValue (clip). */
#define BK_REFORMAT_KERNEL_BODY \
    if (gid.x >= p.width || gid.y >= p.height) return; \
    bk_float4 b4 = frames[gid.x * 3u], r4 = frames[gid.x * 3u + 1u], s4 = frames[gid.x * 3u + 2u]; \
    bk_float3 base = b4.xyz, row = r4.xyz, slab = s4.xyz; \
    float ry = float(gid.y) - p.rowCentre; \
    float acc = 0.0f; \
    uint n = 0u; \
    for (uint z = 0u; z < p.depth; z++) { \
        float rz = float(z) - p.slabCentre; \
        if (p.bandEnabled != 0u) { \
            float h = b4.w + r4.w * ry + s4.w * rz; \
            if (!(h >= p.bandLow && h <= p.bandHigh)) continue; \
        } \
        bk_float3 c = base + row * ry + slab * rz; \
        if (!bkr_in_band(BKR_P_FIRST_ARG c)) continue; \
        float value = bkr_sample(vol BKR_P_ARG, c); \
        if (p.projection == 1)      acc = (n == 0u || value > acc) ? value : acc; \
        else if (p.projection == 2) acc = (n == 0u || value < acc) ? value : acc; \
        else if (p.projection == 3) acc = (n == 0u) ? value : (acc * float(n) + value) / float(n + 1u); \
        else if (p.projection == 4) acc += (max(value, -1000.0f) + 1000.0f) * p.radiographK; \
        else if (n == 0u) acc = value; \
        n++; \
    } \
    if (p.bandEnabled != 0u && n == 0u) acc = p.bandOutsideValue; \
    else if (n == 0u) acc = p.outOfBoundsValue; \
    else if (p.projection == 4) acc = 3000.0f - 4000.0f * exp(-acc); \
    outValues[gid.y * p.width + gid.x] = acc;

#endif
