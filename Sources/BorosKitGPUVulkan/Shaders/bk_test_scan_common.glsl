// BorosKitGPUVulkan: shared pieces of the compute test kernels (bk_test_scan_*): prefix sum of a large array.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
// Workgroup size = specialization constants 0..2 (BKGPU.h ComputeDesc), so gl_WorkGroupSize sizes the shared array.
#ifndef BK_TEST_SCAN_COMMON
#define BK_TEST_SCAN_COMMON
layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;
layout(std430, set = 0, binding = 0) readonly buffer BKScanParams { uint count; uint blocks; } P;
shared uint bkScratch[gl_WorkGroupSize.x];

// Workgroup exclusive prefix sum (Hillis-Steele on shared memory; the Metal twin is in BKGPUTestMetal.mm and
// BKSurfaceShaderSource.mm): returns the sum of the values of the threads before this one; `total` = all.
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
