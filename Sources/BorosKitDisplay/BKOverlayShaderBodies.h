// BorosKitDisplay: BKOverlayShaderBodies.h - the 2D overlay engine's shaders (BKOverlayRenderer) written ONCE for
// Metal and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #6, shader option C): moved operation for operation
// from BKOverlayRenderer.mm, so the Metal pictures stay bit-identical (golden strict). The CPU rasteriser
// BKOverlayRasterize stays the reference.
//
// PORTING NOTES:
//   - Only #defines (pasted into the MSL, #included by GLSL bk_overlay_*.vert/.frag). No // comments inside.
//   - Shared subset: bk_float2 / bk_float4; bko_texture2d / bko_sampler (parameter types); BKO_SAMPLE(t, s, uv)
//     (filtered read, normalised coordinates); BKO_P_PARAM / BKO_P_ARG (params block p); BKO_FN.
//   - Vertex: view pixels (y down) -> clip space (y up; Vulkan keeps it with its negative-height viewport).
//   - Fragment: straight alpha in (colour x image or x mask), premultiplied out (blend: one, one-minus-source-alpha).

#ifndef BK_OVERLAY_SHADER_BODIES_H
#define BK_OVERLAY_SHADER_BODIES_H

#define BK_OVERLAY_BODIES \
BKO_FN bk_float4 bk_overlay_clip(bk_float2 position BKO_P_PARAM) \
{ \
    return bk_float4(position.x / p.viewSize.x * 2.0 - 1.0, 1.0 - position.y / p.viewSize.y * 2.0, 0.0, 1.0); \
} \
BKO_FN bk_float4 bk_overlay_shade(bk_float4 color, bk_float2 uv, bko_texture2d image, bko_sampler smp BKO_P_PARAM) \
{ \
    bk_float4 c = color; \
    if (p.mode != 0) { \
        bk_float4 t = BKO_SAMPLE(image, smp, uv / p.imageSize); \
        if (p.mode == 1) c *= t; \
        else c.a *= t.r; \
    } \
    if (p.opaque != 0) c.a = 1.0; \
    return bk_float4(c.rgb * c.a, c.a); \
}

#endif
