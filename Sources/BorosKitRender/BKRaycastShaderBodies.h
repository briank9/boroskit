// BorosKitRender: BKRaycastShaderBodies.h - the volume ray caster written ONCE for Metal and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 #4b, shader option C as BKMeshShaderBodies.h): the
// helpers and kernels were moved here from BKShaderSource.mm operation for operation (only C-style casts became
// constructor casts, INFINITY became BK_INF, texture access went through macros, and the local `step` became
// `stepLen` because step() is a GLSL built-in), so the Metal pictures stay bit-identical (golden strict).
//
// PORTING NOTES (Vulkan / other backends):
//   - Only #defines, read by Metal (BKShaderSource.mm pastes the text in with BK_STRINGIFY) and by GLSL
//     (Sources/BorosKitGPUVulkan/Shaders/bk_raycast*.comp, bk_brick_*.comp via bk_raycast_common.glsl). Never
//     compiled as C. No // comments and no # directives inside the macros.
//   - Shared subset (each language's prelude defines it): bk_float2/3/4, bk_int3, bk_uint2/3/4, bk_float3x3;
//     bk_texture2d / bk_texture3d / bk_sampler (parameter types); BK_TEX2_READ / BK_TEX3_READ (exact texel),
//     BK_TEX2_SAMPLE / BK_TEX3_SAMPLE (filtered), BK_TEX2_WIDTH / BK_TEX2_HEIGHT; BK_INF; bk_fabs; bk_rint;
//     bk_all_ge / bk_all_le / bk_any_ge (vector comparisons); BK_FN; BK_OUT(type, name) / BK_INOUT(type, name);
//     BK_P_PARAM / BK_P_ARG (the params block p: Metal parameter, GLSL global), BK_P_ONLY_PARAM / BK_P_ONLY_ARG
//     (the same for functions with p as their only parameter), BK_BRICK_PARAM / BK_BRICK_ARG (the brick lists);
//     BK_TRACE_SAMPLERS (Metal: the two constexpr samplers; GLSL: nothing, linearSampler / tfSampler name the bound
//     sampler); constants BKModeComposite.. BKModeAverage, BKProjPerspective, BKBrickSize,
//     BKTransferFunctionEntries, BKMaxClipPlanes.
//   - Resources by the same names in both languages: p, volume, transferFn, geometryColor, geometryDistance,
//     blendVolume, blendFn, colorOut, valueOut, brickEmpty, brickRange, alphaCount, grid4.
//   - Vulkan format notes (unchanged from the MSL): linear filtering of R16_UNORM 3D and RGBA32F 2D images is an
//     optional format feature; p.manualFiltering = 1 reads exact texels instead (the manual path).
//
// Plain language: the recipe that follows a ray through the scan for every pixel, written in one place so the Mac
// engine (Metal) and the Windows / Linux engine (Vulkan) cannot drift apart.

#ifndef BK_RAYCAST_SHADER_BODIES_H
#define BK_RAYCAST_SHADER_BODIES_H

/* Helpers of the grey path (see BKShaderSource.mm history for the long comments): the patient -> voxel matrix;
 * the real value at a voxel position (hardware or manual trilinear); the colour table lookup (hardware or manual,
 * same position rule texel = x * entries - 0.5); the patient-space gradient; RGBA8 packing in one word; brick range
 * unpacking; empty-space skipping (brick of a position, flat index, first sample past a brick); the trace result. */
#define BK_RAYCAST_HELPER_BODIES \
BK_FN bk_float3x3 bk_patient_to_voxel(BK_P_ONLY_PARAM) \
{ \
    return bk_float3x3(p.patientToVoxelColumns[0].xyz, p.patientToVoxelColumns[1].xyz, p.patientToVoxelColumns[2].xyz); \
} \
BK_FN float bk_sample(bk_texture3d volume, bk_sampler s, bk_float3 voxel BK_P_PARAM) \
{ \
    if (p.manualFiltering != 0) { \
        bk_float3 last = p.volumeSize.xyz - 1.0f; \
        bk_float3 v = clamp(voxel, bk_float3(0.0f), last); \
        bk_float3 base = floor(v); \
        bk_float3 f = v - base; \
        bk_uint3 a = bk_uint3(base); \
        bk_uint3 b = bk_uint3(min(base + 1.0f, last)); \
        float c000 = BK_TEX3_READ(volume, bk_uint3(a.x, a.y, a.z)).r, c100 = BK_TEX3_READ(volume, bk_uint3(b.x, a.y, a.z)).r; \
        float c010 = BK_TEX3_READ(volume, bk_uint3(a.x, b.y, a.z)).r, c110 = BK_TEX3_READ(volume, bk_uint3(b.x, b.y, a.z)).r; \
        float c001 = BK_TEX3_READ(volume, bk_uint3(a.x, a.y, b.z)).r, c101 = BK_TEX3_READ(volume, bk_uint3(b.x, a.y, b.z)).r; \
        float c011 = BK_TEX3_READ(volume, bk_uint3(a.x, b.y, b.z)).r, c111 = BK_TEX3_READ(volume, bk_uint3(b.x, b.y, b.z)).r; \
        float c0 = mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y); \
        float c1 = mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y); \
        return mix(c0, c1, f.z) * p.valueScale + p.valueOffset; \
    } \
    bk_float3 tc = (voxel + 0.5f) / p.volumeSize.xyz; \
    return BK_TEX3_SAMPLE(volume, s, tc).r * p.valueScale + p.valueOffset; \
} \
BK_FN bk_float4 bk_transfer(bk_texture2d transferFn, bk_sampler s, float x BK_P_PARAM) \
{ \
    if (p.manualFiltering != 0) { \
        float entries = float(BKTransferFunctionEntries); \
        float t = clamp(x * entries - 0.5f, 0.0f, entries - 1.0f); \
        float i0 = floor(t); \
        float i1 = min(i0 + 1.0f, entries - 1.0f); \
        bk_float4 c0 = BK_TEX2_READ(transferFn, bk_uint2(uint(i0), 0u)); \
        bk_float4 c1 = BK_TEX2_READ(transferFn, bk_uint2(uint(i1), 0u)); \
        return mix(c0, c1, t - i0); \
    } \
    return BK_TEX2_SAMPLE(transferFn, s, bk_float2(x, 0.5f)); \
} \
BK_FN bk_float3 bk_gradient(bk_texture3d volume, bk_sampler s, bk_float3 v BK_P_PARAM) \
{ \
    bk_float3 g; \
    g.x = bk_sample(volume, s, v + bk_float3(1,0,0) BK_P_ARG) - bk_sample(volume, s, v - bk_float3(1,0,0) BK_P_ARG); \
    g.y = bk_sample(volume, s, v + bk_float3(0,1,0) BK_P_ARG) - bk_sample(volume, s, v - bk_float3(0,1,0) BK_P_ARG); \
    g.z = bk_sample(volume, s, v + bk_float3(0,0,1) BK_P_ARG) - bk_sample(volume, s, v - bk_float3(0,0,1) BK_P_ARG); \
    return transpose(bk_patient_to_voxel(BK_P_ONLY_ARG)) * (0.5f * g); \
} \
BK_FN uint bk_pack(bk_float4 c) \
{ \
    bk_uint4 q = bk_uint4(clamp(c, 0.0f, 1.0f) * 255.0f + 0.5f); \
    return q.x | (q.y << 8) | (q.z << 16) | (q.w << 24); \
} \
BK_FN bk_uint2 bk_unpack_range(uint packedRange) \
{ \
    return bk_uint2(packedRange & 0xffffu, packedRange >> 16); \
} \
BK_FN bk_int3 bk_brick_of(bk_float3 v BK_P_PARAM) \
{ \
    bk_int3 last = bk_int3(p.brickGrid.xyz) - 1; \
    return clamp(bk_int3(floor(v * (1.0f / float(BKBrickSize)))), bk_int3(0), last); \
} \
BK_FN uint bk_brick_index(bk_int3 b BK_P_PARAM) \
{ \
    bk_uint3 g = bk_uint3(p.brickGrid.xyz); \
    return (uint(b.z) * g.y + uint(b.y)) * g.x + uint(b.x); \
} \
BK_FN int bk_first_sample_after_brick(bk_int3 b, bk_float3 ov, bk_float3 dv, float tLo, float stepLen, int i, int n) \
{ \
    bk_float3 lo = bk_float3(b * BKBrickSize); \
    bk_float3 hi = lo + float(BKBrickSize); \
    bk_float3 tWall; \
    for (int k = 0; k < 3; k++) { \
        if (dv[k] > 0.0f)      tWall[k] = (hi[k] - ov[k]) / dv[k]; \
        else if (dv[k] < 0.0f) tWall[k] = (lo[k] - ov[k]) / dv[k]; \
        else                   tWall[k] = BK_INF; \
    } \
    float tExit = min(tWall.x, min(tWall.y, tWall.z)); \
    float next = ceil((tExit - tLo) / stepLen - 0.5f); \
    return int(clamp(next, float(i + 1), float(n))); \
} \
struct BKTraceResult { \
    float value; \
    bk_float4 color; \
};

/* The grey ray (bk_trace): ray of pixel gid in patient space, clipped to the crop box (voxel space; affine, so t is
 * the same parameter), the slab, the clipping plane and the extra planes, then marched: composite (front-to-back,
 * opacity correction, Phong head-light, early termination, empty-space skipping of see-through bricks) or
 * MIP / MinIP / average (skipping bricks that cannot change the result). Embedded objects: dropped outside the slab;
 * in 3D the ray stops at the nearest opaque object and the objects are laid under the volume's colour; in the
 * projections they are laid over the grey picture. */
#define BK_RAYCAST_TRACE_BODY \
BK_FN BKTraceResult bk_trace(bk_texture3d volume, bk_texture2d transferFn BK_P_PARAM, bk_uint2 gid BK_BRICK_PARAM, \
                             float geomT, bk_float4 geomColor) \
{ \
    BK_TRACE_SAMPLERS \
    float u = (float(gid.x) + 0.5f) / float(p.width) - 0.5f; \
    float w = 0.5f - (float(gid.y) + 0.5f) / float(p.height); \
    bk_float3 origin, dir; \
    float tLo, tHi; \
    if (p.projection == BKProjPerspective) { \
        origin = p.cameraPosition.xyz; \
        dir = normalize(p.cameraForward.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight)); \
        tLo = 0.0f; tHi = BK_INF; \
    } else { \
        origin = p.cameraPosition.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight); \
        dir = p.cameraForward.xyz; \
        tLo = -BK_INF; tHi = BK_INF; \
    } \
    bk_float3x3 patientToVoxel = bk_patient_to_voxel(BK_P_ONLY_ARG); \
    bk_float3 ov = patientToVoxel * origin + p.patientToVoxelTranslation.xyz; \
    bk_float3 dv = patientToVoxel * dir; \
    bk_float3 inv = 1.0f / dv; \
    bk_float3 boxMin = p.boxMin.xyz, boxMax = p.boxMax.xyz; \
    bk_float3 t0 = (boxMin - ov) * inv; \
    bk_float3 t1 = (boxMax - ov) * inv; \
    bk_float3 tSmall = min(t0, t1), tBig = max(t0, t1); \
    for (int k = 0; k < 3; k++) { \
        if (dv[k] == 0.0f) { \
            bool inside = ov[k] >= boxMin[k] && ov[k] <= boxMax[k]; \
            tSmall[k] = inside ? -BK_INF : BK_INF; \
            tBig[k]   = inside ?  BK_INF : -BK_INF; \
        } \
    } \
    tLo = max(tLo, max(tSmall.x, max(tSmall.y, tSmall.z))); \
    tHi = min(tHi, min(tBig.x, min(tBig.y, tBig.z))); \
    bool singlePlane = false; \
    float slabLo = -BK_INF, slabHi = BK_INF; \
    if (p.useSlab != 0) { \
        float s0 = dot(origin - p.slabPoint.xyz, p.slabNormal.xyz); \
        float dn = dot(dir, p.slabNormal.xyz); \
        float halfThick = 0.5f * p.slabThickness; \
        if (p.slabThickness <= 0.0f) { \
            if (bk_fabs(dn) < 1e-6f) { tHi = -BK_INF; slabHi = -BK_INF; } \
            else { float t = -s0 / dn; tLo = max(tLo, t); tHi = min(tHi, t); singlePlane = true; slabLo = slabHi = t; } \
        } else if (bk_fabs(dn) < 1e-6f) { \
            if (bk_fabs(s0) > halfThick) { tHi = -BK_INF; slabHi = -BK_INF; } \
        } else { \
            float ta = (-halfThick - s0) / dn, tb = (halfThick - s0) / dn; \
            tLo = max(tLo, min(ta, tb)); \
            tHi = min(tHi, max(ta, tb)); \
            slabLo = min(ta, tb); slabHi = max(ta, tb); \
        } \
    } \
    if (p.useClip != 0) { \
        float c0 = dot(origin - p.clipPoint.xyz, p.clipNormal.xyz); \
        float cn = dot(dir, p.clipNormal.xyz); \
        if (bk_fabs(cn) < 1e-6f) { \
            if (c0 > 0.0f) tHi = -BK_INF; \
        } else if (cn > 0.0f) { \
            tHi = min(tHi, -c0 / cn); \
        } else { \
            tLo = max(tLo, -c0 / cn); \
        } \
    } \
    for (int i = 0; i < p.clipPlaneCount && i < BKMaxClipPlanes; i++) { \
        bk_float3 n = p.clipPlanes[i].xyz; \
        float c0 = dot(origin, n) + p.clipPlanes[i].w; \
        float cn = dot(dir, n); \
        if (bk_fabs(cn) < 1e-6f) { \
            if (c0 > 0.0f) tHi = -BK_INF; \
        } else if (cn > 0.0f) { \
            tHi = min(tHi, -c0 / cn); \
        } else { \
            tLo = max(tLo, -c0 / cn); \
        } \
    } \
    bool composite = (p.mode == BKModeComposite); \
    BKTraceResult r; \
    if (p.useGeometry != 0 && p.useSlab != 0 && !(geomT >= slabLo && geomT <= slabHi)) { \
        geomT = BK_INF; \
        geomColor = bk_float4(0.0f); \
    } \
    if (composite && geomT < tHi) tHi = geomT; \
    if (!(tHi >= tLo) || isinf(tLo) || isinf(tHi)) { \
        r.value = composite ? geomColor.a : p.outOfBoundsValue; \
        r.color = composite ? geomColor : bk_float4(geomColor.rgb + (1.0f - geomColor.a) * bk_float3(0.0f), 1.0f); \
        return r; \
    } \
    int n = singlePlane ? 1 : max(1, int(ceil((tHi - tLo) / p.stepSize))); \
    float stepLen = singlePlane ? 0.0f : (tHi - tLo) / float(n); \
    bool skip = (p.skipEmptySpace != 0) && !singlePlane; \
    int brickEnd = 0; \
    if (composite) { \
        bk_float3 color = bk_float3(0.0f); \
        float alpha = 0.0f; \
        bk_float3 light = -dir; \
        float exponent = (singlePlane ? p.stepSize : stepLen) / p.opacityUnitDistance; \
        float tfRange = max(p.tfMax - p.tfMin, 1e-6f); \
        bool brickIsEmpty = false; \
        for (int i = 0; i < n && alpha < 0.99f; i++) { \
            float t = tLo + (float(i) + 0.5f) * stepLen; \
            bk_float3 v = ov + t * dv; \
            if (skip) { \
                if (i >= brickEnd) { \
                    bk_int3 b = bk_brick_of(v BK_P_ARG); \
                    brickEnd = bk_first_sample_after_brick(b, ov, dv, tLo, stepLen, i, n); \
                    brickIsEmpty = brickEmpty[bk_brick_index(b BK_P_ARG)] != 0u; \
                } \
                if (brickIsEmpty) { \
                    i = brickEnd - 1; \
                    continue; \
                } \
            } \
            float value = bk_sample(volume, linearSampler, v BK_P_ARG); \
            bk_float4 c = bk_transfer(transferFn, tfSampler, (value - p.tfMin) / tfRange BK_P_ARG); \
            if (c.a <= 0.0f) continue; \
            float a = 1.0f - pow(1.0f - min(c.a, 0.9999f), exponent); \
            bk_float3 rgb = c.rgb; \
            if (p.shading != 0) { \
                bk_float3 g = bk_gradient(volume, linearSampler, v BK_P_ARG); \
                float len = length(g); \
                if (len > 1e-3f) { \
                    float ndl = bk_fabs(dot(g / len, light)); \
                    rgb = rgb * (p.ambient + p.diffuse * ndl) + p.specular * pow(ndl, p.specularPower); \
                } else { \
                    rgb = rgb * (p.ambient + p.diffuse); \
                } \
            } \
            color += (1.0f - alpha) * a * rgb; \
            alpha += (1.0f - alpha) * a; \
        } \
        color += (1.0f - alpha) * geomColor.rgb; \
        alpha += (1.0f - alpha) * geomColor.a; \
        r.value = alpha; \
        r.color = bk_float4(color, alpha); \
        return r; \
    } \
    float result = (p.mode == BKModeMIP) ? -BK_INF : (p.mode == BKModeMinIP ? BK_INF : 0.0f); \
    bool skipProjection = skip && (p.mode == BKModeMIP || p.mode == BKModeMinIP); \
    float brickLow = 0.0f, brickHigh = 0.0f; \
    for (int i = 0; i < n; i++) { \
        float t = tLo + (float(i) + 0.5f) * stepLen; \
        if (skipProjection) { \
            if (i >= brickEnd) { \
                bk_int3 b = bk_brick_of(ov + t * dv BK_P_ARG); \
                brickEnd = bk_first_sample_after_brick(b, ov, dv, tLo, stepLen, i, n); \
                bk_uint2 raw = bk_unpack_range(brickRange[bk_brick_index(b BK_P_ARG)]); \
                brickLow  = (max(float(raw.x) - 1.0f, 0.0f) / 65535.0f) * p.valueScale + p.valueOffset; \
                brickHigh = (min(float(raw.y) + 1.0f, 65535.0f) / 65535.0f) * p.valueScale + p.valueOffset; \
            } \
            bool cannotChange = (p.mode == BKModeMIP) ? (brickHigh <= result) : (brickLow >= result); \
            if (cannotChange) { \
                i = brickEnd - 1; \
                continue; \
            } \
        } \
        float value = bk_sample(volume, linearSampler, ov + t * dv BK_P_ARG); \
        if (p.mode == BKModeMIP) result = max(result, value); \
        else if (p.mode == BKModeMinIP) result = min(result, value); \
        else result += value; \
    } \
    if (p.mode == BKModeAverage) result /= float(n); \
    float gray = clamp((result - (p.windowCenter - 0.5f * p.windowWidth)) / max(p.windowWidth, 1e-6f), 0.0f, 1.0f); \
    r.value = result; \
    r.color = bk_float4(geomColor.rgb + (1.0f - geomColor.a) * bk_float3(gray), 1.0f); \
    return r; \
}

/* Colour (RGB) scans and fusion (the CPU reference is BKVolumeFusionCore.h, mirrored line by line): 4-channel
 * sampling, table lookup over [lo, hi], step opacity, colour-scan step, mixing two steps, inside-a-box test, ray / box
 * interval, head-light terms, colour gradient, the first scan's and the fused scan's 3D steps. */
#define BK_RAYCAST_COLOR_BODIES \
BK_FN bk_float4 bk_sample4(bk_texture3d volume, bk_sampler s, bk_float3 voxel, bk_float3 size, int manual) \
{ \
    if (manual != 0) { \
        bk_float3 last = size - 1.0f; \
        bk_float3 v = clamp(voxel, bk_float3(0.0f), last); \
        bk_float3 base = floor(v); \
        bk_float3 f = v - base; \
        bk_uint3 a = bk_uint3(base); \
        bk_uint3 b = bk_uint3(min(base + 1.0f, last)); \
        bk_float4 c000 = BK_TEX3_READ(volume, bk_uint3(a.x, a.y, a.z)), c100 = BK_TEX3_READ(volume, bk_uint3(b.x, a.y, a.z)); \
        bk_float4 c010 = BK_TEX3_READ(volume, bk_uint3(a.x, b.y, a.z)), c110 = BK_TEX3_READ(volume, bk_uint3(b.x, b.y, a.z)); \
        bk_float4 c001 = BK_TEX3_READ(volume, bk_uint3(a.x, a.y, b.z)), c101 = BK_TEX3_READ(volume, bk_uint3(b.x, a.y, b.z)); \
        bk_float4 c011 = BK_TEX3_READ(volume, bk_uint3(a.x, b.y, b.z)), c111 = BK_TEX3_READ(volume, bk_uint3(b.x, b.y, b.z)); \
        bk_float4 c0 = mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y); \
        bk_float4 c1 = mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y); \
        return mix(c0, c1, f.z); \
    } \
    return BK_TEX3_SAMPLE(volume, s, (voxel + 0.5f) / size); \
} \
BK_FN bk_float4 bk_table(bk_texture2d fn, bk_sampler s, float value, float lo, float hi BK_P_PARAM) \
{ \
    return bk_transfer(fn, s, (value - lo) / max(hi - lo, 1e-6f) BK_P_ARG); \
} \
BK_FN float bk_step_opacity(float tableOpacity, float exponent) \
{ \
    if (!(tableOpacity > 0.0f)) return 0.0f; \
    return 1.0f - pow(1.0f - min(tableOpacity, 0.9999f), exponent); \
} \
BK_FN bk_float4 bk_color_step(bk_float3 rgb, bk_texture2d fn, bk_sampler s, float lo, float hi, float exponent, \
                              int useTable BK_P_PARAM) \
{ \
    bk_float3 premult = bk_float3(0.0f); \
    float alpha = 0.0f; \
    for (int c = 0; c < 3; c++) { \
        bk_float4 e = bk_table(fn, s, rgb[c], lo, hi BK_P_ARG); \
        float a = bk_step_opacity(e.a, exponent); \
        if (!(a > 0.0f)) continue; \
        bk_float3 colour = bk_float3(0.0f); \
        if (useTable != 0) colour = e.rgb; \
        else colour[c] = clamp(rgb[c] / 255.0f, 0.0f, 1.0f); \
        premult += a * colour; \
        alpha += a; \
    } \
    alpha = min(alpha, 1.0f); \
    return bk_float4(min(premult, bk_float3(alpha)), alpha); \
} \
BK_FN bk_float4 bk_mix_steps(bk_float4 a, bk_float4 b) \
{ \
    if (!(b.a > 0.0f)) return (a.a > 0.0f) ? a : bk_float4(0.0f); \
    if (!(a.a > 0.0f)) return b; \
    float sum = a.a + b.a; \
    float alpha = 1.0f - (1.0f - a.a) * (1.0f - b.a); \
    return bk_float4((a.rgb + b.rgb) * (alpha / sum), alpha); \
} \
BK_FN bool bk_inside(bk_float3 v, bk_float3 lo, bk_float3 hi) \
{ \
    return bk_all_ge(v, lo - 1e-3f) && bk_all_le(v, hi + 1e-3f); \
} \
BK_FN void bk_box_interval(bk_float3 ov, bk_float3 dv, bk_float3 boxMin, bk_float3 boxMax, BK_INOUT(float, tLo), BK_INOUT(float, tHi)) \
{ \
    bk_float3 inv = 1.0f / dv; \
    bk_float3 t0 = (boxMin - ov) * inv; \
    bk_float3 t1 = (boxMax - ov) * inv; \
    bk_float3 tSmall = min(t0, t1), tBig = max(t0, t1); \
    for (int k = 0; k < 3; k++) { \
        if (dv[k] == 0.0f) { \
            bool inside = ov[k] >= boxMin[k] && ov[k] <= boxMax[k]; \
            tSmall[k] = inside ? -BK_INF : BK_INF; \
            tBig[k]   = inside ?  BK_INF : -BK_INF; \
        } \
    } \
    tLo = max(tLo, max(tSmall.x, max(tSmall.y, tSmall.z))); \
    tHi = min(tHi, min(tBig.x, min(tBig.y, tBig.z))); \
} \
BK_FN bk_float2 bk_light_terms(bk_float3 g, bk_float3 light BK_P_PARAM) \
{ \
    float len = length(g); \
    if (len > 1e-3f) { \
        float ndl = bk_fabs(dot(g / len, light)); \
        return bk_float2(p.ambient + p.diffuse * ndl, p.specular * pow(ndl, p.specularPower)); \
    } \
    return bk_float2(p.ambient + p.diffuse, 0.0f); \
} \
BK_FN bk_float3 bk_gradient_rgb(bk_texture3d volume, bk_sampler s, bk_float3 v BK_P_PARAM) \
{ \
    bk_float3 size = p.volumeSize.xyz; \
    int m = p.manualFiltering; \
    const bk_float3 third = bk_float3(1.0f / 3.0f); \
    bk_float3 g; \
    g.x = dot(bk_sample4(volume, s, v + bk_float3(1,0,0), size, m).rgb - bk_sample4(volume, s, v - bk_float3(1,0,0), size, m).rgb, third); \
    g.y = dot(bk_sample4(volume, s, v + bk_float3(0,1,0), size, m).rgb - bk_sample4(volume, s, v - bk_float3(0,1,0), size, m).rgb, third); \
    g.z = dot(bk_sample4(volume, s, v + bk_float3(0,0,1), size, m).rgb - bk_sample4(volume, s, v - bk_float3(0,0,1), size, m).rgb, third); \
    return transpose(bk_patient_to_voxel(BK_P_ONLY_ARG)) * (0.5f * p.valueScale * g); \
} \
BK_FN bk_float4 bk_main_step(bk_texture3d volume, bk_texture2d transferFn, bk_sampler vs, bk_sampler ts, bk_float3 v, \
                             float exponent, bk_float3 light BK_P_PARAM) \
{ \
    if (p.colorVolume != 0) { \
        bk_float3 rgb = bk_sample4(volume, vs, v, p.volumeSize.xyz, p.manualFiltering).rgb * p.valueScale + p.valueOffset; \
        bk_float4 st = bk_color_step(rgb, transferFn, ts, p.tfMin, p.tfMax, exponent, p.colorUsesTable BK_P_ARG); \
        if (!(st.a > 0.0f)) return bk_float4(0.0f); \
        if (p.shading != 0) { \
            bk_float2 l = bk_light_terms(bk_gradient_rgb(volume, vs, v BK_P_ARG), light BK_P_ARG); \
            st.rgb = st.rgb * l.x + st.a * l.y; \
        } \
        return st; \
    } \
    float value = bk_sample(volume, vs, v BK_P_ARG); \
    bk_float4 c = bk_table(transferFn, ts, value, p.tfMin, p.tfMax BK_P_ARG); \
    float a = bk_step_opacity(c.a, exponent); \
    if (!(a > 0.0f)) return bk_float4(0.0f); \
    bk_float3 rgb = c.rgb; \
    if (p.shading != 0) { \
        bk_float2 l = bk_light_terms(bk_gradient(volume, vs, v BK_P_ARG), light BK_P_ARG); \
        rgb = rgb * l.x + l.y; \
    } \
    return bk_float4(a * rgb, a); \
} \
BK_FN bk_float4 bk_blend_step(bk_texture3d blendVolume, bk_texture2d blendFn, bk_sampler vs, bk_sampler ts, bk_float3 vb, \
                              float exponent BK_P_PARAM) \
{ \
    bk_float4 texel = bk_sample4(blendVolume, vs, vb, p.blendVolumeSize.xyz, p.manualFiltering); \
    if (p.blendColorVolume != 0) \
        return bk_color_step(texel.rgb * p.blendValueScale + p.blendValueOffset, blendFn, ts, p.blendTfMin, p.blendTfMax, exponent, 0 BK_P_ARG); \
    bk_float4 c = bk_table(blendFn, ts, texel.r * p.blendValueScale + p.blendValueOffset, p.blendTfMin, p.blendTfMax BK_P_ARG); \
    float a = bk_step_opacity(c.a, exponent); \
    return bk_float4(a * c.rgb, a); \
}

/* The colour / fusion ray (bk_trace_ext): same camera, slab, clip, crop-plane and object rules as bk_trace; the ray
 * covers both scans' boxes; 3D mixes both scans per step; MIP / MinIP / mean: the first scan gives the picture and
 * the value, the fused scan's own projection is laid over it through its table. */
#define BK_RAYCAST_TRACE_EXT_BODY \
BK_FN BKTraceResult bk_trace_ext(bk_texture3d volume, bk_texture2d transferFn, bk_texture3d blendVolume, bk_texture2d blendFn \
                                 BK_P_PARAM, bk_uint2 gid, float geomT, bk_float4 geomColor) \
{ \
    BK_TRACE_SAMPLERS \
    float u = (float(gid.x) + 0.5f) / float(p.width) - 0.5f; \
    float w = 0.5f - (float(gid.y) + 0.5f) / float(p.height); \
    bk_float3 origin, dir; \
    float tBase0, tBase1; \
    if (p.projection == BKProjPerspective) { \
        origin = p.cameraPosition.xyz; \
        dir = normalize(p.cameraForward.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight)); \
        tBase0 = 0.0f; tBase1 = BK_INF; \
    } else { \
        origin = p.cameraPosition.xyz + p.cameraRight.xyz * (u * p.viewWidth) + p.cameraUp.xyz * (w * p.viewHeight); \
        dir = p.cameraForward.xyz; \
        tBase0 = -BK_INF; tBase1 = BK_INF; \
    } \
    bk_float3x3 patientToVoxel = bk_patient_to_voxel(BK_P_ONLY_ARG); \
    bk_float3 ov = patientToVoxel * origin + p.patientToVoxelTranslation.xyz; \
    bk_float3 dv = patientToVoxel * dir; \
    float mLo = tBase0, mHi = tBase1; \
    bk_box_interval(ov, dv, p.boxMin.xyz, p.boxMax.xyz, mLo, mHi); \
    bool hasMain = (mHi >= mLo) && !isinf(mLo) && !isinf(mHi); \
    bk_float3 ob = bk_float3(0.0f), db = bk_float3(0.0f); \
    bk_float3 blendMax = p.blendVolumeSize.xyz - 1.0f; \
    bool hasBlend = false; \
    if (p.useBlend != 0) { \
        bk_float3x3 toBlend = bk_float3x3(p.blendPatientToVoxelColumns[0].xyz, p.blendPatientToVoxelColumns[1].xyz, p.blendPatientToVoxelColumns[2].xyz); \
        ob = toBlend * origin + p.blendPatientToVoxelTranslation.xyz; \
        db = toBlend * dir; \
        float bLo = tBase0, bHi = tBase1; \
        bk_box_interval(ob, db, bk_float3(0.0f), blendMax, bLo, bHi); \
        hasBlend = (bHi >= bLo) && !isinf(bLo) && !isinf(bHi); \
        if (hasBlend && hasMain) { mLo = min(mLo, bLo); mHi = max(mHi, bHi); } \
        else if (hasBlend) { mLo = bLo; mHi = bHi; } \
    } \
    float tLo = mLo, tHi = mHi; \
    if (!hasMain && !hasBlend) { tLo = 0.0f; tHi = -BK_INF; } \
    bool singlePlane = false; \
    float slabLo = -BK_INF, slabHi = BK_INF; \
    if (p.useSlab != 0) { \
        float s0 = dot(origin - p.slabPoint.xyz, p.slabNormal.xyz); \
        float dn = dot(dir, p.slabNormal.xyz); \
        float halfThick = 0.5f * p.slabThickness; \
        if (p.slabThickness <= 0.0f) { \
            if (bk_fabs(dn) < 1e-6f) { tHi = -BK_INF; slabHi = -BK_INF; } \
            else { float t = -s0 / dn; tLo = max(tLo, t); tHi = min(tHi, t); singlePlane = true; slabLo = slabHi = t; } \
        } else if (bk_fabs(dn) < 1e-6f) { \
            if (bk_fabs(s0) > halfThick) { tHi = -BK_INF; slabHi = -BK_INF; } \
        } else { \
            float ta = (-halfThick - s0) / dn, tb = (halfThick - s0) / dn; \
            tLo = max(tLo, min(ta, tb)); \
            tHi = min(tHi, max(ta, tb)); \
            slabLo = min(ta, tb); slabHi = max(ta, tb); \
        } \
    } \
    if (p.useClip != 0) { \
        float c0 = dot(origin - p.clipPoint.xyz, p.clipNormal.xyz); \
        float cn = dot(dir, p.clipNormal.xyz); \
        if (bk_fabs(cn) < 1e-6f) { if (c0 > 0.0f) tHi = -BK_INF; } \
        else if (cn > 0.0f) tHi = min(tHi, -c0 / cn); \
        else tLo = max(tLo, -c0 / cn); \
    } \
    for (int i = 0; i < p.clipPlaneCount && i < BKMaxClipPlanes; i++) { \
        bk_float3 n = p.clipPlanes[i].xyz; \
        float c0 = dot(origin, n) + p.clipPlanes[i].w; \
        float cn = dot(dir, n); \
        if (bk_fabs(cn) < 1e-6f) { if (c0 > 0.0f) tHi = -BK_INF; } \
        else if (cn > 0.0f) tHi = min(tHi, -c0 / cn); \
        else tLo = max(tLo, -c0 / cn); \
    } \
    bool composite = (p.mode == BKModeComposite); \
    BKTraceResult r; \
    if (p.useGeometry != 0 && p.useSlab != 0 && !(geomT >= slabLo && geomT <= slabHi)) { \
        geomT = BK_INF; \
        geomColor = bk_float4(0.0f); \
    } \
    if (composite && geomT < tHi) tHi = geomT; \
    if (!(tHi >= tLo) || isinf(tLo) || isinf(tHi)) { \
        r.value = composite ? geomColor.a : p.outOfBoundsValue; \
        r.color = composite ? geomColor : bk_float4(geomColor.rgb + (1.0f - geomColor.a) * bk_float3(0.0f), 1.0f); \
        return r; \
    } \
    int n = singlePlane ? 1 : max(1, int(ceil((tHi - tLo) / p.stepSize))); \
    float stepLen = singlePlane ? 0.0f : (tHi - tLo) / float(n); \
    if (composite) { \
        bk_float3 color = bk_float3(0.0f); \
        float alpha = 0.0f; \
        bk_float3 light = -dir; \
        float len = singlePlane ? p.stepSize : stepLen; \
        float expMain = len / p.opacityUnitDistance; \
        float expBlend = len / max(p.blendOpacityUnitDistance, 1e-6f); \
        for (int i = 0; i < n && alpha < 0.99f; i++) { \
            float t = tLo + (float(i) + 0.5f) * stepLen; \
            bk_float4 s = bk_float4(0.0f); \
            bk_float3 v = ov + t * dv; \
            if (hasMain && bk_inside(v, p.boxMin.xyz, p.boxMax.xyz)) \
                s = bk_main_step(volume, transferFn, linearSampler, tfSampler, v, expMain, light BK_P_ARG); \
            if (hasBlend) { \
                bk_float3 vb = ob + t * db; \
                if (bk_inside(vb, bk_float3(0.0f), blendMax)) \
                    s = bk_mix_steps(s, bk_blend_step(blendVolume, blendFn, linearSampler, tfSampler, vb, expBlend BK_P_ARG)); \
            } \
            if (!(s.a > 0.0f)) continue; \
            color += (1.0f - alpha) * s.rgb; \
            alpha += (1.0f - alpha) * s.a; \
        } \
        color += (1.0f - alpha) * geomColor.rgb; \
        alpha += (1.0f - alpha) * geomColor.a; \
        r.value = alpha; \
        r.color = bk_float4(color, alpha); \
        return r; \
    } \
    bool isMax = (p.mode == BKModeMIP), isMin = (p.mode == BKModeMinIP); \
    float start = isMax ? -BK_INF : (isMin ? BK_INF : 0.0f); \
    float result = start; \
    bk_float3 resultRGB = bk_float3(start); \
    int mainCount = 0; \
    bool blendMaxMode = (p.blendProjection == 1); \
    float bres = blendMaxMode ? -BK_INF : BK_INF; \
    bk_float3 bresRGB = bk_float3(bres); \
    int blendCount = 0; \
    for (int i = 0; i < n; i++) { \
        float t = tLo + (float(i) + 0.5f) * stepLen; \
        bk_float3 v = ov + t * dv; \
        if (hasMain && bk_inside(v, p.boxMin.xyz, p.boxMax.xyz)) { \
            if (p.colorVolume != 0) { \
                bk_float3 rgb = bk_sample4(volume, linearSampler, v, p.volumeSize.xyz, p.manualFiltering).rgb * p.valueScale + p.valueOffset; \
                if (isMax) resultRGB = max(resultRGB, rgb); \
                else if (isMin) resultRGB = min(resultRGB, rgb); \
                else resultRGB += rgb; \
            } else { \
                float value = bk_sample(volume, linearSampler, v BK_P_ARG); \
                if (isMax) result = max(result, value); \
                else if (isMin) result = min(result, value); \
                else result += value; \
            } \
            mainCount++; \
        } \
        if (hasBlend) { \
            bk_float3 vb = ob + t * db; \
            if (bk_inside(vb, bk_float3(0.0f), blendMax)) { \
                bk_float4 texel = bk_sample4(blendVolume, linearSampler, vb, p.blendVolumeSize.xyz, p.manualFiltering); \
                if (p.blendColorVolume != 0) { \
                    bk_float3 rgb = texel.rgb * p.blendValueScale + p.blendValueOffset; \
                    bresRGB = blendMaxMode ? max(bresRGB, rgb) : min(bresRGB, rgb); \
                } else { \
                    float value = texel.r * p.blendValueScale + p.blendValueOffset; \
                    bres = blendMaxMode ? max(bres, value) : min(bres, value); \
                } \
                blendCount++; \
            } \
        } \
    } \
    bk_float3 under = bk_float3(0.0f); \
    float lowEnd = p.windowCenter - 0.5f * p.windowWidth, width = max(p.windowWidth, 1e-6f); \
    if (mainCount == 0) { \
        r.value = p.outOfBoundsValue; \
    } else if (p.colorVolume != 0) { \
        if (!isMax && !isMin) resultRGB /= float(mainCount); \
        r.value = (resultRGB.r + resultRGB.g + resultRGB.b) / 3.0f; \
        under = clamp((resultRGB - lowEnd) / width, 0.0f, 1.0f); \
    } else { \
        if (!isMax && !isMin) result /= float(mainCount); \
        r.value = result; \
        under = bk_float3(clamp((result - lowEnd) / width, 0.0f, 1.0f)); \
    } \
    if (blendCount > 0) { \
        bk_float4 over; \
        if (p.blendColorVolume != 0) over = bk_color_step(bresRGB, blendFn, tfSampler, p.blendTfMin, p.blendTfMax, 1.0f, 0 BK_P_ARG); \
        else { \
            bk_float4 c = bk_table(blendFn, tfSampler, bres, p.blendTfMin, p.blendTfMax BK_P_ARG); \
            float a = bk_step_opacity(c.a, 1.0f); \
            over = bk_float4(a * c.rgb, a); \
        } \
        under = over.rgb + (1.0f - over.a) * under; \
    } \
    r.color = bk_float4(geomColor.rgb + (1.0f - geomColor.a) * under, 1.0f); \
    return r; \
}

/* The embedded objects under output pixel gid: ray distance (mm) and premultiplied colour from the geometry pictures
 * (the texel under the output pixel's centre; the pictures may be bigger than the output). None: BK_INF, 0. */
#define BK_RAYCAST_GEOMETRY_BODY \
BK_FN void bk_geometry_at(BK_P_PARAM_FIRST bk_uint2 gid, bk_texture2d geometryColor, bk_texture2d geometryDistance, \
                          BK_OUT(float, geomT), BK_OUT(bk_float4, geomColor)) \
{ \
    geomT = BK_INF; \
    geomColor = bk_float4(0.0f); \
    if (p.useGeometry == 0) return; \
    uint gw = BK_TEX2_WIDTH(geometryDistance), gh = BK_TEX2_HEIGHT(geometryDistance); \
    if (gw == 0u || gh == 0u) return; \
    uint gx = min(uint((float(gid.x) + 0.5f) * float(gw) / float(p.width)), gw - 1u); \
    uint gy = min(uint((float(gid.y) + 0.5f) * float(gh) / float(p.height)), gh - 1u); \
    geomT = BK_TEX2_READ(geometryDistance, bk_uint2(gx, gy)).r; \
    geomColor = BK_TEX2_READ(geometryColor, bk_uint2(gx, gy)); \
}

/* Kernel bodies (the entry points provide gid and the resources). bk_raycast: one thread = one output pixel into
 * the CPU-readable buffers (RGBA8 packed in one word + float value). */
#define BK_RAYCAST_KERNEL_BODY \
    if (gid.x >= p.width || gid.y >= p.height) return; \
    uint index = gid.y * p.width + gid.x; \
    float geomT; bk_float4 geomColor; \
    bk_geometry_at(BK_P_ARG_FIRST gid, geometryColor, geometryDistance, geomT, geomColor); \
    BKTraceResult r = (p.colorVolume != 0 || p.useBlend != 0) \
        ? bk_trace_ext(volume, transferFn, blendVolume, blendFn BK_P_ARG, gid, geomT, geomColor) \
        : bk_trace(volume, transferFn BK_P_ARG, gid BK_BRICK_ARG, geomT, geomColor); \
    valueOut[index] = r.value; \
    if (p.valuesOnly == 0) colorOut[index] = bk_pack(r.color);

/* bk_brick_ranges (once per volume): per brick the lowest and highest stored value over the brick plus one voxel on
 * every side, as raw 16-bit steps, packed lowest | highest << 16. volumeSize3 = the texture size (int3). */
#define BK_BRICK_RANGES_BODY \
    bk_uint3 grid = grid4.xyz; \
    if (bk_any_ge(gid, grid)) return; \
    bk_int3 last = volumeSize3 - 1; \
    bk_int3 lo = max(bk_int3(gid) * BKBrickSize - 1, bk_int3(0)); \
    bk_int3 hi = min(bk_int3(gid) * BKBrickSize + BKBrickSize + 1, last); \
    float mn = 1.0f, mx = 0.0f; \
    for (int z = lo.z; z <= hi.z; z++) \
        for (int y = lo.y; y <= hi.y; y++) \
            for (int x = lo.x; x <= hi.x; x++) { \
                float v = BK_TEX3_READ(volume, bk_uint3(x, y, z)).r; \
                mn = min(mn, v); \
                mx = max(mx, v); \
            } \
    uint index = (gid.z * grid.y + gid.y) * grid.x + gid.x; \
    brickRange[index] = uint(bk_rint(mn * 65535.0f)) | (uint(bk_rint(mx * 65535.0f)) << 16);

/* bk_classify_bricks (whenever the colour / opacity rule changes): a brick is see-through when every table entry a
 * ray could read for a value in its range (plus one entry of margin each side) has zero opacity. */
#define BK_CLASSIFY_BRICKS_BODY \
    bk_uint3 g = bk_uint3(p.brickGrid.xyz); \
    if (bk_any_ge(gid, g)) return; \
    uint index = (gid.z * g.y + gid.y) * g.x + gid.x; \
    bk_uint2 raw = bk_unpack_range(brickRange[index]); \
    float tfRange = max(p.tfMax - p.tfMin, 1e-6f); \
    float lowValue  = (float(raw.x) / 65535.0f) * p.valueScale + p.valueOffset; \
    float highValue = (float(raw.y) / 65535.0f) * p.valueScale + p.valueOffset; \
    float entries = float(BKTransferFunctionEntries); \
    float texLow  = (lowValue  - p.tfMin) / tfRange * entries - 0.5f; \
    float texHigh = (highValue - p.tfMin) / tfRange * entries - 0.5f; \
    int first = int(floor(clamp(texLow,  -4.0f, entries + 4.0f))) - 1; \
    int last  = int(floor(clamp(texHigh, -4.0f, entries + 4.0f))) + 2; \
    first = clamp(first, 0, BKTransferFunctionEntries - 1); \
    last  = clamp(last,  0, BKTransferFunctionEntries - 1); \
    bool empty = (alphaCount[last + 1] - alphaCount[first]) == 0u; \
    brickEmpty[index] = empty ? 1u : 0u;

#endif
