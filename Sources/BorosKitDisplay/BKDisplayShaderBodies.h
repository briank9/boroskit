// BorosKitDisplay: BKDisplayShaderBodies.h - the 2D image display shaders (BKImageLayerRenderer) written ONCE for Metal
// and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #6, shader option C): moved operation for operation
// from BKDisplayShaderSource.mm, so the Metal pictures stay bit-identical (golden strict).
//
// PORTING NOTES:
//   - Only #defines, pasted into the MSL (BKDisplayShaderSource.mm) and #included by GLSL
//     (Sources/BorosKitGPUVulkan/Shaders/bk_display_*.vert/.frag). No // comments or # directives inside.
//   - Shared subset: bk_float2 / bk_float4 / bk_int2 / bk_uint2; bkd_texture2d (parameter type); BKD_READ(t, c)
//     (exact texel, c integer pixel); BKD_P_PARAM / BKD_P_ARG (params block p); BKD_FN.
//   - The fragment is a function of the fragment's window position (device pixel centre, y DOWN: Metal
//     [[position]].xy; GLSL gl_FragCoord.xy - also top-left origin in Vulkan).
//   - Full-screen triangle: BK_DISPLAY_TRIANGLE(vid) = the clip-space xy of vertex vid (Vulkan's negative-height
//     viewport keeps clip y up, as Metal).

#ifndef BK_DISPLAY_SHADER_BODIES_H
#define BK_DISPLAY_SHADER_BODIES_H

#define BK_DISPLAY_TRIANGLE(vid) bk_float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0)

/* bk_read: one image pixel, clamped to the edge (all four channels: grey in .r, colour in .rgb).
 * bk_display_shade: the image point under a device pixel (inverse view transform), nearest or bilinear by hand,
 * then a finished colour picture as is (own alpha for see-through layers), or window / level, invert, colour table. */
#define BK_DISPLAY_BODIES \
BKD_FN bk_float4 bk_read(bkd_texture2d image, bk_int2 c BKD_P_PARAM) \
{ \
    c = clamp(c, bk_int2(0), bk_int2(int(p.imageWidth) - 1, int(p.imageHeight) - 1)); \
    return BKD_READ(image, c); \
} \
BKD_FN bk_float4 bk_display_shade(bk_float2 position, bkd_texture2d image, bkd_texture2d lut BKD_P_PARAM) \
{ \
    bk_float4 background = bk_float4(p.bgR, p.bgG, p.bgB, p.bgA); \
    bk_float2 v = position / p.scale; \
    bk_float2 img = bk_float2(p.m_a * v.x + p.m_c * v.y + p.m_tx, \
                              p.m_b * v.x + p.m_d * v.y + p.m_ty); \
    if (img.x < 0.0 || img.y < 0.0 || img.x >= p.imageWidth || img.y >= p.imageHeight) \
        return background; \
    bk_float4 smp; \
    if (p.interpolation == 1) { \
        bk_float2 f = img - 0.5; \
        bk_float2 base = floor(f); \
        bk_float2 w = f - base; \
        bk_int2 b = bk_int2(base); \
        bk_float4 v00 = bk_read(image, b BKD_P_ARG); \
        bk_float4 v10 = bk_read(image, b + bk_int2(1, 0) BKD_P_ARG); \
        bk_float4 v01 = bk_read(image, b + bk_int2(0, 1) BKD_P_ARG); \
        bk_float4 v11 = bk_read(image, b + bk_int2(1, 1) BKD_P_ARG); \
        smp = mix(mix(v00, v10, w.x), mix(v01, v11, w.x), w.y); \
    } else { \
        smp = bk_read(image, bk_int2(floor(img)) BKD_P_ARG); \
    } \
    if (p.colorImage != 0) \
        return bk_float4(smp.rgb, p.useImageAlpha != 0 ? smp.a : 1.0); \
    float value = smp.r; \
    float t = (p.windowWidth > 0.0) ? (value - p.windowLower) / p.windowWidth \
                                    : (value >= p.windowLower ? 1.0 : 0.0); \
    t = clamp(t, 0.0, 1.0); \
    if (p.invert != 0) \
        t = 1.0 - t; \
    if (p.useColorTable != 0) { \
        uint index = uint(t * 255.0 + 0.5); \
        bk_float4 c = BKD_READ(lut, bk_uint2(index, 0u)); \
        return bk_float4(c.rgb, 1.0); \
    } \
    return bk_float4(t, t, t, 1.0); \
}

#endif
