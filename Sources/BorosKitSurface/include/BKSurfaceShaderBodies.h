// BorosKitSurface: BKSurfaceShaderBodies.h - the four surface-extraction kernels written ONCE for Metal and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (shader option C, as BKMeshShaderBodies.h): the bodies were moved
// here from BKSurfaceShaderSource.mm operation for operation, so the Metal surfaces stay bit-identical (golden
// strict), and they replace the line-by-line GLSL twins of phase 3/4.
//
// PORTING NOTES (Vulkan / other backends):
//   - Only #defines, read by Metal (BKSurfaceShaderSource.mm pastes the text in with BK_SURFACE_STRINGIFY) and by
//     GLSL (Sources/BorosKitGPUVulkan/Shaders/bk_surface_*.comp #include this file through bk_surface_common.glsl).
//     Never compiled as C. No // comments and no # directives inside the macros (stringified / one line).
//   - Shared subset: types bk_uint3 / bk_float3 / bk_float4 / bk_float3x3 / bk_float4x4; bk_rint (Metal rint =
//     GLSL roundEven: round half to even), bk_popcount, bk_barrier() (workgroup barrier + shared memory);
//     BK_FN = static (Metal) / nothing (GLSL); BK_OUT_UINT(name) = an out parameter; uints compared with != 0u.
//   - Resources by the SAME names in both languages: P (BKSurfaceParams), fieldWords (binding 1), blurOut (2, blur),
//     packedWords (2), rowVertexWords (3), rowTriangleWords (4), tableWords (5), positionsOut (6), normalsOut (7),
//     indexWords (8); Metal gets them as kernel parameters, GLSL as anonymous storage blocks. The scan texture and
//     sampler only through BK_VOLUME_READ(p) / BK_VOLUME_SAMPLE(coord); 16-bit reads through BK_READ16(words, i).
//   - Helper functions reach the resources through BK_SURF_PARAM / BK_SURF_ARG (Metal: extra parameters; GLSL:
//     empty, the globals are used) and the workgroup scan array through BK_SCAN_PARAM / BK_SCAN_ARG.
//   - Kernel bodies are statement lists: the thin entry points (Metal kernel functions / GLSL main) declare the
//     shared arrays bkScratch / bkValues16 and the names gid (sample, blur) or group, lid, n (classify, emit).
//   - Identifiers avoid GLSL reserved words (packed, sample, out, filter, input, output, half ...).
//
// Plain language: the recipe that turns a scan into a surface, written in one place so the Mac engine (Metal) and
// the Windows / Linux engine (Vulkan) cannot drift apart.

#ifndef BK_SURFACE_SHADER_BODIES_H
#define BK_SURFACE_SHADER_BODIES_H

/* Helpers. Values are in "steps" (the stored 16-bit number as a float). bk_index: position of grid point p in the
 * packed 16-bit buffers (rows of rowStride values, y fastest, then z). bk_value: the scan value at p, straight from
 * the texture when the grid IS the voxel grid, else from the field. bk_gradient: central differences, one-sided at
 * the border (must match BKReferenceGradient in BKSurfaceCore.c). bk_workgroup_exclusive_scan: Hillis-Steele prefix
 * sum in shared memory (all threads of the group call it). bk_cell_case: marching-cubes case of the cell whose first
 * corner is p, or 256 if p has no cell. bk_sample_steps: value at a fractional voxel position, manual path = 8 exact
 * reads + interpolation in float (same numbers on every GPU), hardware path = the linear filter (Vulkan: needs
 * SAMPLED_IMAGE_FILTER_LINEAR for R16_UNORM 3D). */
#define BK_SURFACE_HELPER_BODIES \
BK_FN uint bk_index(bk_uint3 p BK_SURF_PARAM) \
{ \
    return (p.z * P.gridSize[1] + p.y) * P.gridSize[3] + p.x; \
} \
BK_FN float bk_value(bk_uint3 p BK_SURF_PARAM) \
{ \
    if (P.source == BK_SURFACE_SOURCE_TEXTURE) \
        return bk_rint(BK_VOLUME_READ(p) * 65535.0f); \
    return float(BK_READ16(fieldWords, bk_index(p BK_SURF_ARG))); \
} \
BK_FN bk_float3 bk_gradient(bk_uint3 p BK_SURF_PARAM) \
{ \
    bk_float3 g; \
    for (uint a = 0u; a < 3u; a++) { \
        bk_uint3 lo = p, hi = p; \
        lo[a] = p[a] > 0u ? p[a] - 1u : 0u; \
        hi[a] = p[a] + 1u < P.gridSize[a] ? p[a] + 1u : p[a]; \
        g[a] = (bk_value(hi BK_SURF_ARG) - bk_value(lo BK_SURF_ARG)) / float(hi[a] - lo[a]); \
    } \
    return g; \
} \
BK_FN uint bk_workgroup_exclusive_scan(uint value, uint lid, uint n BK_SCAN_PARAM, BK_OUT_UINT(total)) \
{ \
    bkScratch[lid] = value; \
    bk_barrier(); \
    for (uint offset = 1u; offset < n; offset <<= 1u) { \
        uint add = lid >= offset ? bkScratch[lid - offset] : 0u; \
        bk_barrier(); \
        bkScratch[lid] += add; \
        bk_barrier(); \
    } \
    uint inclusive = bkScratch[lid]; \
    total = bkScratch[n - 1u]; \
    bk_barrier(); \
    return inclusive - value; \
} \
BK_FN uint bk_cell_case(bk_uint3 p BK_SURF_PARAM) \
{ \
    if (p.x + 1u >= P.gridSize[0] || p.y + 1u >= P.gridSize[1] || p.z + 1u >= P.gridSize[2]) return 256u; \
    uint cs = 0u; \
    for (uint c = 0u; c < 8u; c++) { \
        bk_uint3 q = p + bk_uint3(c & 1u, (c >> 1) & 1u, (c >> 2) & 1u); \
        if (bk_value(q BK_SURF_ARG) >= P.thresholdSteps) cs |= 1u << c; \
    } \
    return cs; \
} \
BK_FN float bk_sample_steps(bk_float3 voxel BK_SURF_PARAM) \
{ \
    if (P.sampling == BK_SURFACE_SAMPLING_MANUAL) { \
        bk_uint3 last = bk_uint3(P.volumeSize[0], P.volumeSize[1], P.volumeSize[2]) - 1u; \
        voxel = clamp(voxel, bk_float3(0.0f), bk_float3(last)); \
        bk_float3 base = floor(voxel); \
        bk_float3 f = voxel - base; \
        bk_uint3 a = bk_uint3(base); \
        bk_uint3 b = min(a + 1u, last); \
        float c000 = BK_VOLUME_READ(bk_uint3(a.x, a.y, a.z)), c100 = BK_VOLUME_READ(bk_uint3(b.x, a.y, a.z)); \
        float c010 = BK_VOLUME_READ(bk_uint3(a.x, b.y, a.z)), c110 = BK_VOLUME_READ(bk_uint3(b.x, b.y, a.z)); \
        float c001 = BK_VOLUME_READ(bk_uint3(a.x, a.y, b.z)), c101 = BK_VOLUME_READ(bk_uint3(b.x, a.y, b.z)); \
        float c011 = BK_VOLUME_READ(bk_uint3(a.x, b.y, b.z)), c111 = BK_VOLUME_READ(bk_uint3(b.x, b.y, b.z)); \
        float c00 = mix(c000, c100, f.x), c10 = mix(c010, c110, f.x); \
        float c01 = mix(c001, c101, f.x), c11 = mix(c011, c111, f.x); \
        float c0 = mix(c00, c10, f.y), c1 = mix(c01, c11, f.y); \
        return mix(c0, c1, f.z) * 65535.0f; \
    } \
    bk_float3 coord = (voxel + 0.5f) * bk_float3(P.volumeSizeInv[0], P.volumeSizeInv[1], P.volumeSizeInv[2]); \
    return BK_VOLUME_SAMPLE(coord) * 65535.0f; \
}

/* 1. sample: scan -> 16-bit field at the grid points. One thread (gid) per PAIR of grid points along x, so each
 * thread writes one whole 32-bit word; the padding value of an odd-width row stays 0. */
#define BK_SURFACE_SAMPLE_BODY \
    uint pairs = P.gridSize[3] / 2u; \
    if (gid.x >= pairs || gid.y >= P.gridSize[1] || gid.z >= P.gridSize[2]) return; \
    bk_float3 scale = bk_float3(P.gridToVoxel[0], P.gridToVoxel[1], P.gridToVoxel[2]); \
    uint word = 0u; \
    for (uint k = 0u; k < 2u; k++) { \
        uint x = 2u * gid.x + k; \
        if (x >= P.gridSize[0]) break; \
        float v = bk_sample_steps(bk_float3(x, gid.y, gid.z) * scale BK_SURF_ARG); \
        word |= uint(clamp(bk_rint(v), 0.0f, 65535.0f)) << (16u * k); \
    } \
    fieldWords[(gid.z * P.gridSize[1] + gid.y) * pairs + gid.x] = word;

/* 2. blur: one direction of the separable Gaussian, fieldWords -> blurOut, edges repeated (a voxel past the border
 * counts as the border voxel). One thread per pair. */
#define BK_SURFACE_BLUR_BODY \
    uint pairs = P.gridSize[3] / 2u; \
    if (gid.x >= pairs || gid.y >= P.gridSize[1] || gid.z >= P.gridSize[2]) return; \
    uint axis = P.blurAxis; \
    int last = int(P.gridSize[axis]) - 1; \
    uint word = 0u; \
    for (uint k = 0u; k < 2u; k++) { \
        bk_uint3 p = bk_uint3(2u * gid.x + k, gid.y, gid.z); \
        if (p.x >= P.gridSize[0]) break; \
        float acc = P.blurWeights[0] * float(BK_READ16(fieldWords, bk_index(p BK_SURF_ARG))); \
        for (uint o = 1u; o <= P.blurRadius; o++) { \
            bk_uint3 lo = p, hi = p; \
            lo[axis] = uint(max(int(p[axis]) - int(o), 0)); \
            hi[axis] = uint(min(int(p[axis]) + int(o), last)); \
            acc += P.blurWeights[o] * (float(BK_READ16(fieldWords, bk_index(lo BK_SURF_ARG))) + float(BK_READ16(fieldWords, bk_index(hi BK_SURF_ARG)))); \
        } \
        word |= uint(clamp(bk_rint(acc), 0.0f, 65535.0f)) << (16u * k); \
    } \
    blurOut[(gid.z * P.gridSize[1] + gid.y) * pairs + gid.x] = word;

/* 3. classify: one workgroup per grid row (group = (y, z)), threads along x, looping in chunks of n. Per grid point:
 * which of its own edges (+x, +y, +z) the surface crosses (3-bit mask) and how many triangles its cell makes; a
 * workgroup prefix sum of the vertex counts gives each point its first vertex number in the row, stored as 16 bits
 * (vertex << 3) | mask. Vertex and triangle counts travel together in one 32-bit number (low / high 16 bits). Two
 * neighbouring points share one word: gathered in bkValues16, the even thread writes the pair. Per row: totals. */
#define BK_SURFACE_CLASSIFY_BODY \
    const uint y = group.x, z = group.y; \
    const uint W = P.gridSize[0], H = P.gridSize[1], D = P.gridSize[2]; \
    const float T = P.thresholdSteps; \
    uint carry = 0u; \
    for (uint x0 = 0u; x0 < P.gridSize[3]; x0 += n) { \
        uint x = x0 + lid; \
        uint mask = 0u, triangles = 0u; \
        if (x < W) { \
            bk_uint3 p = bk_uint3(x, y, z); \
            bool in0 = bk_value(p BK_SURF_ARG) >= T; \
            if (x + 1u < W && (bk_value(p + bk_uint3(1u, 0u, 0u) BK_SURF_ARG) >= T) != in0) mask |= 1u; \
            if (y + 1u < H && (bk_value(p + bk_uint3(0u, 1u, 0u) BK_SURF_ARG) >= T) != in0) mask |= 2u; \
            if (z + 1u < D && (bk_value(p + bk_uint3(0u, 0u, 1u) BK_SURF_ARG) >= T) != in0) mask |= 4u; \
            uint cs = bk_cell_case(p BK_SURF_ARG); \
            if (cs < 256u) triangles = tableWords[cs * BK_SURFACE_CASE_STRIDE]; \
        } \
        uint vertices = bk_popcount(mask); \
        uint total; \
        uint before = bk_workgroup_exclusive_scan(vertices | (triangles << 16), lid, n BK_SCAN_ARG, total) + carry; \
        bkValues16[lid] = ((before & 0xffffu) << 3) | mask; \
        bk_barrier(); \
        if ((lid & 1u) == 0u && x < P.gridSize[3]) \
            packedWords[bk_index(bk_uint3(x, y, z) BK_SURF_ARG) >> 1] = bkValues16[lid] | (bkValues16[lid + 1u] << 16); \
        bk_barrier(); \
        carry += total; \
    } \
    if (lid == 0u) { \
        uint row = y + z * H; \
        rowVertexWords[row] = carry & 0xffffu; \
        rowTriangleWords[row] = carry >> 16; \
    }

/* 4. emit: same rows as classify; rowVertexWords / rowTriangleWords now hold each row's first vertex / triangle
 * (CPU prefix sum). a) each point writes the vertices on its crossed edges: position by linear interpolation along
 * the edge, normal from the value gradient pointing toward LOWER values, both into output coordinates; b) each cell
 * writes its triangles; a corner on an edge is found through the edge's owner point (its row start + its vertex
 * number in the row + its crossed edges before this one), so shared edges give shared vertices (no cracks). */
#define BK_SURFACE_EMIT_BODY \
    const uint y = group.x, z = group.y; \
    const uint W = P.gridSize[0], H = P.gridSize[1]; \
    const uint row = y + z * H; \
    const float T = P.thresholdSteps; \
    const bk_float4x4 M = bk_float4x4(bk_float4(P.gridToOutput[0], P.gridToOutput[1], P.gridToOutput[2], P.gridToOutput[3]), \
                                      bk_float4(P.gridToOutput[4], P.gridToOutput[5], P.gridToOutput[6], P.gridToOutput[7]), \
                                      bk_float4(P.gridToOutput[8], P.gridToOutput[9], P.gridToOutput[10], P.gridToOutput[11]), \
                                      bk_float4(P.gridToOutput[12], P.gridToOutput[13], P.gridToOutput[14], P.gridToOutput[15])); \
    const bk_float3x3 N = bk_float3x3(bk_float3(P.normalMatrix[0], P.normalMatrix[1], P.normalMatrix[2]), \
                                      bk_float3(P.normalMatrix[4], P.normalMatrix[5], P.normalMatrix[6]), \
                                      bk_float3(P.normalMatrix[8], P.normalMatrix[9], P.normalMatrix[10])); \
    const uint vertexStart = rowVertexWords[row]; \
    const uint triangleStart = rowTriangleWords[row]; \
    uint carry = 0u; \
    for (uint x0 = 0u; x0 < W; x0 += n) { \
        uint x = x0 + lid; \
        bk_uint3 p = bk_uint3(x, y, z); \
        uint cs = 256u, triangles = 0u; \
        if (x < W) { \
            uint pk = BK_READ16(packedWords, bk_index(p BK_SURF_ARG)); \
            uint mask = pk & 7u; \
            if (mask != 0u) { \
                uint v = vertexStart + (pk >> 3); \
                float v0 = bk_value(p BK_SURF_ARG); \
                bk_float3 g0 = bk_gradient(p BK_SURF_ARG); \
                for (uint a = 0u; a < 3u; a++) { \
                    if ((mask & (1u << a)) == 0u) continue; \
                    bk_uint3 q = p; \
                    q[a] += 1u; \
                    float v1 = bk_value(q BK_SURF_ARG); \
                    float t = (T - v0) / (v1 - v0); \
                    bk_float3 gp = bk_float3(p); \
                    gp[a] += t; \
                    bk_float3 g = g0 + (bk_gradient(q BK_SURF_ARG) - g0) * t; \
                    bk_float3 outward = -(N * g); \
                    float len = length(outward); \
                    positionsOut[v] = bk_float4((M * bk_float4(gp, 1.0f)).xyz, 0.0f); \
                    normalsOut[v] = bk_float4(len > 0.0f ? outward / len : bk_float3(0.0f), 0.0f); \
                    v++; \
                } \
            } \
            cs = bk_cell_case(p BK_SURF_ARG); \
            if (cs < 256u) triangles = tableWords[cs * BK_SURFACE_CASE_STRIDE]; \
        } \
        uint total; \
        uint before = bk_workgroup_exclusive_scan(triangles, lid, n BK_SCAN_ARG, total); \
        if (triangles != 0u) { \
            uint outIndex = (triangleStart + carry + before) * 3u; \
            for (uint t = 0u; t < triangles; t++) { \
                uint id[3]; \
                for (uint j = 0u; j < 3u; j++) { \
                    uint e = tableWords[cs * BK_SURFACE_CASE_STRIDE + 1u + 3u * t + j]; \
                    uint ed = tableWords[BK_SURFACE_EDGE_TABLE_OFFSET + e]; \
                    bk_uint3 owner = p + bk_uint3(ed & 0xffu, (ed >> 8) & 0xffu, (ed >> 16) & 0xffu); \
                    uint axis = ed >> 24; \
                    uint opk = BK_READ16(packedWords, bk_index(owner BK_SURF_ARG)); \
                    id[j] = rowVertexWords[owner.y + owner.z * H] + (opk >> 3) + bk_popcount(opk & 7u & ((1u << axis) - 1u)); \
                } \
                indexWords[outIndex + 3u * t + 0u] = id[0]; \
                indexWords[outIndex + 3u * t + 1u] = P.flipWinding != 0u ? id[2] : id[1]; \
                indexWords[outIndex + 3u * t + 2u] = P.flipWinding != 0u ? id[1] : id[2]; \
            } \
        } \
        carry += total; \
    }

#endif
