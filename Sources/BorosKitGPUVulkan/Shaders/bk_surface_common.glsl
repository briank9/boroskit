// BorosKitGPUVulkan: bk_surface_common.glsl - shared pieces of the surface extraction kernels (bk_surface_*.comp),
// the GLSL twins of the MSL kernels in Sources/BorosKitSurface/BKSurfaceShaderSource.mm.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 step 3).
//
// PORTING NOTES:
//   - Line-by-line translation of the MSL: same order of operations, same rounding (Metal rint = GLSL roundEven:
//     round half to even), same packing of 16-bit values two per 32-bit word. Any change to the maths must be made
//     in BOTH files (the golden test bk_surface_vulkan compares Vulkan with the Metal references).
//   - The params block is BK_SURFACE_PARAM_FIELDS from BKSurfaceShaderTypes.h (std430 storage buffer, binding 0).
//   - Bindings: see BKSurfacePass.h (storage slot n = binding n; scan texture = binding 16; sampler = binding 40).
//   - Workgroup size = specialization constants 0..2 (BKGPU.h ComputeDesc); shared arrays use gl_WorkGroupSize.x.
//   - A kernel that reads the scan values defines BK_SURFACE_READS_FIELD and the block bkField (binding 1) first.
#ifndef BK_SURFACE_COMMON_GLSL
#define BK_SURFACE_COMMON_GLSL

#define BK_GLSL 1
#define bk_u32 uint
#include "BKSurfaceShaderTypes.h"

layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;
layout(std430, set = 0, binding = 0) readonly buffer BKSurfaceParamsBlock { BK_SURFACE_PARAM_FIELDS } P;
layout(set = 0, binding = 16) uniform texture3D bkVolume;
layout(set = 0, binding = 40) uniform sampler bkSampler;

// Exact stored value of a voxel (R16Unorm read as 0..1).
float bk_volume_read(uvec3 p)
{
    return texelFetch(sampler3D(bkVolume, bkSampler), ivec3(p), 0).r;
}

// Position of grid point p in the packed 16-bit buffers (rows of rowStride values; y fastest, then z).
uint bk_index(uvec3 p)
{
    return (p.z * P.gridSize[1] + p.y) * P.gridSize[3] + p.x;
}

// One 16-bit value out of a buffer of 32-bit words (low half first).
#define BK_READ16(buf, i) (((buf)[(i) >> 1] >> (((i) & 1u) * 16u)) & 0xffffu)

#ifdef BK_SURFACE_READS_FIELD
// The scan value at grid point p (in steps): from the texture when the grid IS the voxel grid, else the field.
float bk_value(uvec3 p)
{
    if (P.source == BK_SURFACE_SOURCE_TEXTURE)
        return roundEven(bk_volume_read(p) * 65535.0);
    return float(BK_READ16(bkField.w, bk_index(p)));
}

// Central-difference gradient (one-sided at the border), in grid units. Must match BKReferenceGradient.
vec3 bk_gradient(uvec3 p)
{
    vec3 g;
    for (uint a = 0u; a < 3u; a++) {
        uvec3 lo = p, hi = p;
        lo[a] = p[a] > 0u ? p[a] - 1u : 0u;
        hi[a] = p[a] + 1u < P.gridSize[a] ? p[a] + 1u : p[a];
        g[a] = (bk_value(hi) - bk_value(lo)) / float(hi[a] - lo[a]);
    }
    return g;
}

// Marching-cubes case of the cell whose first corner is p, or 256 if p has no cell.
uint bk_cell_case(uvec3 p)
{
    if (p.x + 1u >= P.gridSize[0] || p.y + 1u >= P.gridSize[1] || p.z + 1u >= P.gridSize[2]) return 256u;
    uint cs = 0u;
    for (uint c = 0u; c < 8u; c++) {
        uvec3 q = p + uvec3(c & 1u, (c >> 1) & 1u, (c >> 2) & 1u);
        if (bk_value(q) >= P.thresholdSteps) cs |= 1u << c;
    }
    return cs;
}
#endif

#ifdef BK_SURFACE_ROW_KERNEL
shared uint bkScratch[gl_WorkGroupSize.x];
// Workgroup exclusive prefix sum (Hillis-Steele; twin of bk_workgroup_exclusive_scan in the MSL).
uint bk_workgroup_exclusive_scan(uint value, uint lid, uint n, out uint total)
{
    bkScratch[lid] = value;
    barrier();
    for (uint offset = 1u; offset < n; offset <<= 1u) {
        uint add = lid >= offset ? bkScratch[lid - offset] : 0u;
        barrier();
        bkScratch[lid] += add;
        barrier();
    }
    uint inclusive = bkScratch[lid];
    total = bkScratch[n - 1u];
    barrier();
    return inclusive - value;
}
#endif

#endif
