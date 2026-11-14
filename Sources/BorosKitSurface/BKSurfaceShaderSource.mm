// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: the GPU programs ("compute kernels") that build a surface, as Metal
// source compiled at runtime (like the volume and mesh shaders, so the Swift package
// needs no Metal build step and the same code runs on macOS and iOS).

/* BOROS OVERVIEW (plain language)
 * Four small GPU programs, run one after the other by BKSurfaceExtractor:
 *  1. "sample": reads the scan at every grid point (fewer points when the resolution
 *     setting is below 1) into a compact 16-bit working copy;
 *  2. "blur":   optional gentle smoothing of that copy, one direction at a time
 *     (x, then y, then z), to calm scan noise before the surface is built;
 *  3. "classify": for every row of grid points, finds where the surface crosses the
 *     three edges each point owns, and counts the surface points and triangles. The
 *     threads of a row add up their counts together (a "prefix sum"), so every point
 *     knows where its surface points will go in the final list;
 *  4. "emit":   writes the surface points (position + outward direction) and the
 *     triangles into the final lists, at the places worked out in step 3.
 * Between 3 and 4 the CPU adds up the row totals (BKSurfaceExclusiveScan).
 *
 * PORTABILITY (future Vulkan backend): the kernels use only plain compute features that
 * translate line by line to GLSL/HLSL compute shaders: storage buffers of 32-bit words,
 * one sampled 3D texture and one sampler, workgroup ("threadgroup") shared memory with
 * barriers, and uniform loops. No SIMD-group intrinsics, function constants, argument
 * buffers or other Metal-only features. 16-bit values are packed two per 32-bit word by
 * hand, so the Vulkan device needs no 16-bit storage feature.
 */

#import <Foundation/Foundation.h>
#import "BKSurfaceShaderTypes.h"

extern "C" NSString *BKSurfaceShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *prelude = [NSString stringWithFormat:@
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "typedef uint bk_u32;\n"
            "#define BK_SURFACE_ROW_THREADS %d\n"
            "#define BK_SURFACE_MAX_BLUR_WEIGHTS %d\n"
            "#define BK_SURFACE_CASE_STRIDE %d\n"
            "#define BK_SURFACE_EDGE_TABLE_OFFSET %d\n"
            "#define BK_SURFACE_SOURCE_TEXTURE %d\n"
            "#define BK_SURFACE_SAMPLING_MANUAL %d\n",
            BK_SURFACE_ROW_THREADS, BK_SURFACE_MAX_BLUR_WEIGHTS, BK_SURFACE_CASE_STRIDE,
            BK_SURFACE_EDGE_TABLE_OFFSET, BK_SURFACE_SOURCE_TEXTURE, BK_SURFACE_SAMPLING_MANUAL];

        NSString *params = @"struct BKSurfaceParams { " BK_SURFACE_STRINGIFY(BK_SURFACE_PARAM_FIELDS) " };\n";

        const char *functions = R"METAL(
// ---------------------------------------------------------------------------------
// Reading values. All values are in "steps": the stored 16-bit number 0...65535
// (real value = steps / 65535 * valueScale + valueOffset), as floats.
// ---------------------------------------------------------------------------------

// Position of grid point p in the packed 16-bit buffers (field and packed): rows of
// rowStride (even) values, rows ordered y fastest, then z.
static inline uint bk_index(uint3 p, constant BKSurfaceParams &P)
{
    return (p.z * P.gridSize[1] + p.y) * P.gridSize[3] + p.x;
}

// One 16-bit value out of a buffer of 32-bit words (two values per word, low half first).
static inline uint bk_read16(device const uint *words, uint i)
{
    return (words[i >> 1] >> ((i & 1u) * 16u)) & 0xffffu;
}

// The scan value at grid point p: straight from the volume texture when the grid IS
// the voxel grid and nothing is smoothed (saves a full copy), otherwise from the field.
static inline float bk_value(uint3 p, constant BKSurfaceParams &P, device const uint *field,
                             texture3d<float> volume)
{
    if (P.source == BK_SURFACE_SOURCE_TEXTURE)
        return rint(volume.read(p).r * 65535.0f);   // R16Unorm: exact stored step
    return float(bk_read16(field, bk_index(p, P)));
}

// The direction in which the values increase fastest at grid point p (central
// differences; one-sided at the border of the grid), in grid units. Must match
// BKReferenceGradient in BKSurfaceCore.c.
static float3 bk_gradient(uint3 p, constant BKSurfaceParams &P, device const uint *field,
                          texture3d<float> volume)
{
    float3 g;
    for (uint a = 0; a < 3; a++) {
        uint3 lo = p, hi = p;
        lo[a] = p[a] > 0 ? p[a] - 1 : 0;
        hi[a] = p[a] + 1 < P.gridSize[a] ? p[a] + 1 : p[a];
        g[a] = (bk_value(hi, P, field, volume) - bk_value(lo, P, field, volume)) / float(hi[a] - lo[a]);
    }
    return g;
}

// ---------------------------------------------------------------------------------
// Workgroup prefix sum: every thread brings a number and gets back the sum of the
// numbers of the threads BEFORE it ("exclusive scan"); `total` is the sum of all.
// Plain shared memory + barriers (Hillis-Steele), so it ports 1:1 to Vulkan; a faster
// version could use simd_prefix_exclusive_sum (Vulkan: subgroupExclusiveAdd) inside
// this one function. All threads of the group must call it (uniform control flow).
// ---------------------------------------------------------------------------------
static uint bk_workgroup_exclusive_scan(uint value, uint lid, uint n, threadgroup uint *scratch,
                                        thread uint &total)
{
    scratch[lid] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = 1; offset < n; offset <<= 1) {
        uint add = lid >= offset ? scratch[lid - offset] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        scratch[lid] += add;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint inclusive = scratch[lid];
    total = scratch[n - 1];
    threadgroup_barrier(mem_flags::mem_threadgroup);   // scratch may be reused right after
    return inclusive - value;
}

// ---------------------------------------------------------------------------------
// 1. sample: scan -> 16-bit field at the grid points. One thread per PAIR of grid
//    points along x, so each thread writes one whole 32-bit word.
// ---------------------------------------------------------------------------------
// Value (in steps) at a voxel position (fractional voxel index).
// Hardware path: the GPU's linear filter. NOTE for Vulkan: linear filtering of
// R16_UNORM 3D images is an optional format feature
// (VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT); where it is missing, use the
// manual path. Manual path: 8 exact reads and the interpolation in 32-bit float, which
// gives the same numbers on every GPU (the hardware filter may use fewer bits for the
// weights).
static float bk_sample_steps(float3 voxel, constant BKSurfaceParams &P, texture3d<float> volume, sampler s)
{
    if (P.sampling == BK_SURFACE_SAMPLING_MANUAL) {
        uint3 last = uint3(P.volumeSize[0], P.volumeSize[1], P.volumeSize[2]) - 1u;
        voxel = clamp(voxel, float3(0.0f), float3(last));
        float3 base = floor(voxel);
        float3 f = voxel - base;
        uint3 a = uint3(base);
        uint3 b = min(a + 1u, last);
        float c000 = volume.read(uint3(a.x, a.y, a.z)).r, c100 = volume.read(uint3(b.x, a.y, a.z)).r;
        float c010 = volume.read(uint3(a.x, b.y, a.z)).r, c110 = volume.read(uint3(b.x, b.y, a.z)).r;
        float c001 = volume.read(uint3(a.x, a.y, b.z)).r, c101 = volume.read(uint3(b.x, a.y, b.z)).r;
        float c011 = volume.read(uint3(a.x, b.y, b.z)).r, c111 = volume.read(uint3(b.x, b.y, b.z)).r;
        float c00 = mix(c000, c100, f.x), c10 = mix(c010, c110, f.x);
        float c01 = mix(c001, c101, f.x), c11 = mix(c011, c111, f.x);
        float c0 = mix(c00, c10, f.y), c1 = mix(c01, c11, f.y);
        return mix(c0, c1, f.z) * 65535.0f;
    }
    float3 coord = (voxel + 0.5f) * float3(P.volumeSizeInv[0], P.volumeSizeInv[1], P.volumeSizeInv[2]);
    return volume.sample(s, coord).r * 65535.0f;
}

kernel void bk_surface_sample(constant BKSurfaceParams &P [[buffer(0)]],
                              device uint *field [[buffer(1)]],
                              texture3d<float> volume [[texture(0)]],
                              sampler linearSampler [[sampler(0)]],
                              uint3 gid [[thread_position_in_grid]])
{
    uint pairs = P.gridSize[3] / 2;
    if (gid.x >= pairs || gid.y >= P.gridSize[1] || gid.z >= P.gridSize[2]) return;
    float3 scale = float3(P.gridToVoxel[0], P.gridToVoxel[1], P.gridToVoxel[2]);
    uint word = 0;
    for (uint k = 0; k < 2; k++) {
        uint x = 2 * gid.x + k;
        if (x >= P.gridSize[0]) break;   // padding value of an odd-width row stays 0
        float v = bk_sample_steps(float3(x, gid.y, gid.z) * scale, P, volume, linearSampler);
        word |= uint(clamp(rint(v), 0.0f, 65535.0f)) << (16 * k);
    }
    field[(gid.z * P.gridSize[1] + gid.y) * pairs + gid.x] = word;
}

// ---------------------------------------------------------------------------------
// 2. blur: one direction of the separable Gaussian, src -> dst, edges repeated
//    (a voxel past the border counts as the border voxel). One thread per pair.
// ---------------------------------------------------------------------------------
kernel void bk_surface_blur(constant BKSurfaceParams &P [[buffer(0)]],
                            device const uint *src [[buffer(1)]],
                            device uint *dst [[buffer(2)]],
                            uint3 gid [[thread_position_in_grid]])
{
    uint pairs = P.gridSize[3] / 2;
    if (gid.x >= pairs || gid.y >= P.gridSize[1] || gid.z >= P.gridSize[2]) return;
    uint axis = P.blurAxis;
    int last = int(P.gridSize[axis]) - 1;
    uint word = 0;
    for (uint k = 0; k < 2; k++) {
        uint3 p = uint3(2 * gid.x + k, gid.y, gid.z);
        if (p.x >= P.gridSize[0]) break;
        float acc = P.blurWeights[0] * float(bk_read16(src, bk_index(p, P)));
        for (uint o = 1; o <= P.blurRadius; o++) {
            uint3 lo = p, hi = p;
            lo[axis] = uint(max(int(p[axis]) - int(o), 0));
            hi[axis] = uint(min(int(p[axis]) + int(o), last));
            acc += P.blurWeights[o] * (float(bk_read16(src, bk_index(lo, P))) + float(bk_read16(src, bk_index(hi, P))));
        }
        word |= uint(clamp(rint(acc), 0.0f, 65535.0f)) << (16 * k);
    }
    dst[(gid.z * P.gridSize[1] + gid.y) * pairs + gid.x] = word;
}

// ---------------------------------------------------------------------------------
// Shared by classify and emit: the marching-cubes case of the cell whose first
// corner is p (bit c set = corner c inside), or 256 if p has no cell (last point of a
// row/column/slice).
// ---------------------------------------------------------------------------------
static uint bk_cell_case(uint3 p, constant BKSurfaceParams &P, device const uint *field, texture3d<float> volume)
{
    if (p.x + 1 >= P.gridSize[0] || p.y + 1 >= P.gridSize[1] || p.z + 1 >= P.gridSize[2]) return 256u;
    uint cs = 0;
    for (uint c = 0; c < 8; c++) {
        uint3 q = p + uint3(c & 1u, (c >> 1) & 1u, (c >> 2) & 1u);
        if (bk_value(q, P, field, volume) >= P.thresholdSteps) cs |= 1u << c;
    }
    return cs;
}

// ---------------------------------------------------------------------------------
// 3. classify: one workgroup per grid row (group = (y, z)), threads along x, looping
//    in chunks when the row is longer than the workgroup.
//    Per grid point: which of its own three edges (+x, +y, +z) the surface crosses
//    (3-bit mask), and how many triangles its cell makes. A workgroup prefix sum of the
//    vertex counts gives each point the number of the first vertex it will write,
//    counted from the start of the row. Stored per point as 16 bits:
//    (vertex number in row << 3) | mask  (3 * 2048 vertices fit in the 13 bits).
//    Per row: the number of vertices and triangles.
//    Vertex and triangle counts travel together in one 32-bit number (vertices in the
//    low 16 bits, triangles in the high 16 bits: a row has at most 6141 and 10235).
// ---------------------------------------------------------------------------------
kernel void bk_surface_classify(constant BKSurfaceParams &P [[buffer(0)]],
                                device const uint *field [[buffer(1)]],
                                device uint *packed [[buffer(2)]],
                                device uint *rowVertices [[buffer(3)]],
                                device uint *rowTriangles [[buffer(4)]],
                                device const uint *table [[buffer(5)]],
                                texture3d<float> volume [[texture(0)]],
                                uint3 group [[threadgroup_position_in_grid]],
                                uint3 local [[thread_position_in_threadgroup]],
                                uint3 groupSize [[threads_per_threadgroup]])
{
    // (Metal wants all thread-position inputs of the same width, hence uint3.)
    const uint lid = local.x, n = groupSize.x;
    threadgroup uint scratch[BK_SURFACE_ROW_THREADS];
    threadgroup uint values16[BK_SURFACE_ROW_THREADS];
    const uint y = group.x, z = group.y;
    const uint W = P.gridSize[0], H = P.gridSize[1], D = P.gridSize[2];
    const float T = P.thresholdSteps;
    uint carry = 0;   // packed counts of the chunks already done
    for (uint x0 = 0; x0 < P.gridSize[3]; x0 += n) {
        uint x = x0 + lid;
        uint mask = 0, triangles = 0;
        if (x < W) {
            uint3 p = uint3(x, y, z);
            bool in0 = bk_value(p, P, field, volume) >= T;
            if (x + 1 < W && (bk_value(p + uint3(1, 0, 0), P, field, volume) >= T) != in0) mask |= 1u;
            if (y + 1 < H && (bk_value(p + uint3(0, 1, 0), P, field, volume) >= T) != in0) mask |= 2u;
            if (z + 1 < D && (bk_value(p + uint3(0, 0, 1), P, field, volume) >= T) != in0) mask |= 4u;
            uint cs = bk_cell_case(p, P, field, volume);
            if (cs < 256u) triangles = table[cs * BK_SURFACE_CASE_STRIDE];
        }
        uint vertices = popcount(mask);
        uint total;
        uint before = bk_workgroup_exclusive_scan(vertices | (triangles << 16), lid, n, scratch, total) + carry;
        // Two neighbouring points share one 32-bit word: gather in shared memory, then
        // the even thread writes the pair.
        values16[lid] = ((before & 0xffffu) << 3) | mask;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if ((lid & 1u) == 0 && x < P.gridSize[3])
            packed[bk_index(uint3(x, y, z), P) >> 1] = values16[lid] | (values16[lid + 1] << 16);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        carry += total;
    }
    if (lid == 0) {
        uint row = y + z * H;
        rowVertices[row] = carry & 0xffffu;
        rowTriangles[row] = carry >> 16;
    }
}

// ---------------------------------------------------------------------------------
// 4. emit: same rows as classify. rowVertexStart / rowTriangleStart now hold where
//    each row's vertices and triangles start in the final lists (CPU prefix sum).
//    a) each point writes the vertices on its crossed edges: position by linear
//       interpolation along the edge, normal from the value gradient (pointing toward
//       LOWER values = out of the bone), both turned into output coordinates;
//    b) each cell writes its triangles; a triangle corner on an edge is found through
//       the edge's owner point: its row start + its vertex number in the row + how many
//       of its edges before this one are crossed. Shared edges therefore give shared
//       vertex numbers: no duplicated vertices, no cracks.
// ---------------------------------------------------------------------------------
kernel void bk_surface_emit(constant BKSurfaceParams &P [[buffer(0)]],
                            device const uint *field [[buffer(1)]],
                            device const uint *packed [[buffer(2)]],
                            device const uint *rowVertexStart [[buffer(3)]],
                            device const uint *rowTriangleStart [[buffer(4)]],
                            device const uint *table [[buffer(5)]],
                            device float4 *positions [[buffer(6)]],
                            device float4 *normals [[buffer(7)]],
                            device uint *indices [[buffer(8)]],
                            texture3d<float> volume [[texture(0)]],
                                uint3 group [[threadgroup_position_in_grid]],
                                uint3 local [[thread_position_in_threadgroup]],
                                uint3 groupSize [[threads_per_threadgroup]])
{
    // (Metal wants all thread-position inputs of the same width, hence uint3.)
    const uint lid = local.x, n = groupSize.x;
    threadgroup uint scratch[BK_SURFACE_ROW_THREADS];
    const uint y = group.x, z = group.y;
    const uint W = P.gridSize[0], H = P.gridSize[1];
    const uint row = y + z * H;
    const float T = P.thresholdSteps;
    const float4x4 M = float4x4(float4(P.gridToOutput[0], P.gridToOutput[1], P.gridToOutput[2], P.gridToOutput[3]),
                                float4(P.gridToOutput[4], P.gridToOutput[5], P.gridToOutput[6], P.gridToOutput[7]),
                                float4(P.gridToOutput[8], P.gridToOutput[9], P.gridToOutput[10], P.gridToOutput[11]),
                                float4(P.gridToOutput[12], P.gridToOutput[13], P.gridToOutput[14], P.gridToOutput[15]));
    const float3x3 N = float3x3(float3(P.normalMatrix[0], P.normalMatrix[1], P.normalMatrix[2]),
                                float3(P.normalMatrix[4], P.normalMatrix[5], P.normalMatrix[6]),
                                float3(P.normalMatrix[8], P.normalMatrix[9], P.normalMatrix[10]));
    const uint vertexStart = rowVertexStart[row];
    const uint triangleStart = rowTriangleStart[row];
    uint carry = 0;   // triangles of the chunks already done
    for (uint x0 = 0; x0 < W; x0 += n) {
        uint x = x0 + lid;
        uint3 p = uint3(x, y, z);
        uint cs = 256u, triangles = 0;
        if (x < W) {
            // a) vertices on this point's own crossed edges
            uint pk = bk_read16(packed, bk_index(p, P));
            uint mask = pk & 7u;
            if (mask) {
                uint v = vertexStart + (pk >> 3);
                float v0 = bk_value(p, P, field, volume);
                float3 g0 = bk_gradient(p, P, field, volume);
                for (uint a = 0; a < 3; a++) {
                    if (!(mask & (1u << a))) continue;
                    uint3 q = p;
                    q[a] += 1;
                    float v1 = bk_value(q, P, field, volume);
                    float t = (T - v0) / (v1 - v0);
                    float3 gp = float3(p);
                    gp[a] += t;
                    float3 g = g0 + (bk_gradient(q, P, field, volume) - g0) * t;
                    float3 outward = -(N * g);
                    float len = length(outward);
                    positions[v] = float4((M * float4(gp, 1.0f)).xyz, 0.0f);
                    normals[v] = float4(len > 0.0f ? outward / len : float3(0.0f), 0.0f);
                    v++;
                }
            }
            cs = bk_cell_case(p, P, field, volume);
            if (cs < 256u) triangles = table[cs * BK_SURFACE_CASE_STRIDE];
        }
        // b) triangles
        uint total;
        uint before = bk_workgroup_exclusive_scan(triangles, lid, n, scratch, total);
        if (triangles) {
            uint out = (triangleStart + carry + before) * 3;
            for (uint t = 0; t < triangles; t++) {
                uint id[3];
                for (uint j = 0; j < 3; j++) {
                    uint e = table[cs * BK_SURFACE_CASE_STRIDE + 1 + 3 * t + j];
                    uint ed = table[BK_SURFACE_EDGE_TABLE_OFFSET + e];
                    uint3 owner = p + uint3(ed & 0xffu, (ed >> 8) & 0xffu, (ed >> 16) & 0xffu);
                    uint axis = ed >> 24;
                    uint pk = bk_read16(packed, bk_index(owner, P));
                    id[j] = rowVertexStart[owner.y + owner.z * H] + (pk >> 3) + popcount(pk & 7u & ((1u << axis) - 1u));
                }
                indices[out + 3 * t + 0] = id[0];
                indices[out + 3 * t + 1] = P.flipWinding ? id[2] : id[1];
                indices[out + 3 * t + 2] = P.flipWinding ? id[1] : id[2];
            }
        }
        carry += total;
    }
}

// Test helper: lets a unit test check that C and the GPU agree on the struct size.
kernel void bk_surface_params_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKSurfaceParams);
}
)METAL";
        source = [NSString stringWithFormat:@"%@%@%s", prelude, params, functions];
    });
    return source;
}
