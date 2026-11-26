// BorosKit GPU tests: see BKGPUTestMetal.h.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
#import "BKGPUTestMetal.h"
#import "BKGPUMetal.h"
#import "BKMetalDevice.h"

extern "C" NSString *BKMeshShaderSource(void);   // BorosKitMeshRender/BKMeshShaderSource.mm
extern "C" NSString *BKSurfaceShaderSource(void); // BorosKitSurface/BKSurfaceShaderSource.mm
extern "C" NSString *BKVolumeShaderSource(void);  // BorosKitRender/BKShaderSource.mm (2026-11-26: ray caster)
extern "C" NSString *BKReformatShaderSource(void); // BorosKitRender/BKReformatShaderSource.mm (2026-11-26: reformat)

namespace bkshared {

std::unique_ptr<boroskit::gpu::Device> MakeTestMetalDevice()
{
    using namespace boroskit::gpu;
    id<MTLDevice> mtl = [BKMetalDevice preferredDevice];
    if (!mtl) return nullptr;
    std::unique_ptr<Device> device;
    if (makeMetalDevice(mtl, &device) != Status::Ok) return nullptr;
    NSError *error = nil;
    id<MTLLibrary> mesh = [mtl newLibraryWithSource:BKMeshShaderSource() options:[BKMetalDevice shaderCompileOptions] error:&error];
    // The test triangle in MSL (the Vulkan twin: Sources/BorosKitGPUVulkan/Shaders/bk_triangle_*).
    NSString *triangleSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct BKTriangleOut { float4 position [[position]]; };\n"
        "vertex BKTriangleOut bk_triangle_vertex(device const float *xy [[buffer(0)]], uint vid [[vertex_id]]) {\n"
        "    BKTriangleOut o; o.position = float4(xy[vid * 2], xy[vid * 2 + 1], 0.5, 1.0); return o; }\n"
        "fragment float4 bk_triangle_fragment(constant float4 &rgba [[buffer(1)]]) { return rgba; }\n";
    id<MTLLibrary> triangle = [mtl newLibraryWithSource:triangleSource options:[BKMetalDevice shaderCompileOptions] error:&error];
    // The compute test kernels in MSL (twins of Sources/BorosKitGPUVulkan/Shaders/bk_test_scan_*.comp, 2026-11-26).
    NSString *scanSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct BKScanParams { uint count; uint blocks; };\n"
        "static uint bk_scan(uint value, uint lid, uint n, threadgroup uint *s, thread uint &total) {\n"
        "    s[lid] = value; threadgroup_barrier(mem_flags::mem_threadgroup);\n"
        "    for (uint o = 1; o < n; o <<= 1) { uint add = lid >= o ? s[lid - o] : 0u;\n"
        "        threadgroup_barrier(mem_flags::mem_threadgroup); s[lid] += add; threadgroup_barrier(mem_flags::mem_threadgroup); }\n"
        "    uint inclusive = s[lid]; total = s[n - 1]; threadgroup_barrier(mem_flags::mem_threadgroup); return inclusive - value; }\n"
        "kernel void bk_test_scan_blocks(constant BKScanParams &P [[buffer(0)]], device const uint *values [[buffer(1)]],\n"
        "    device uint *outValues [[buffer(2)]], device uint *blockSums [[buffer(3)]],\n"
        "    uint3 g [[threadgroup_position_in_grid]], uint3 l [[thread_position_in_threadgroup]], uint3 gs [[threads_per_threadgroup]]) {\n"
        "    threadgroup uint s[1024]; uint lid = l.x, n = gs.x, idx = g.x * n + lid, total;\n"
        "    uint value = idx < P.count ? values[idx] : 0u; uint before = bk_scan(value, lid, n, s, total);\n"
        "    if (idx < P.count) outValues[idx] = before; if (lid == 0) blockSums[g.x] = total; }\n"
        "kernel void bk_test_scan_sums(constant BKScanParams &P [[buffer(0)]], device const uint *blockSums [[buffer(3)]],\n"
        "    device uint *blockStarts [[buffer(4)]], uint3 l [[thread_position_in_threadgroup]], uint3 gs [[threads_per_threadgroup]]) {\n"
        "    threadgroup uint s[1024]; uint lid = l.x, n = gs.x, carry = 0, total;\n"
        "    for (uint i0 = 0; i0 < P.blocks; i0 += n) { uint i = i0 + lid;\n"
        "        uint before = bk_scan(i < P.blocks ? blockSums[i] : 0u, lid, n, s, total);\n"
        "        if (i < P.blocks) blockStarts[i] = before + carry; carry += total; } }\n"
        "kernel void bk_test_scan_add(constant BKScanParams &P [[buffer(0)]], device uint *outValues [[buffer(2)]],\n"
        "    device const uint *blockStarts [[buffer(4)]], uint3 g [[threadgroup_position_in_grid]],\n"
        "    uint3 l [[thread_position_in_threadgroup]], uint3 gs [[threads_per_threadgroup]]) {\n"
        "    uint idx = g.x * gs.x + l.x; if (idx < P.count) outValues[idx] += blockStarts[g.x]; }\n";
    id<MTLLibrary> scan = [mtl newLibraryWithSource:scanSource options:[BKMetalDevice shaderCompileOptions] error:&error];
    id<MTLLibrary> surface = [mtl newLibraryWithSource:BKSurfaceShaderSource() options:[BKMetalDevice shaderCompileOptions] error:&error];
    if (!mesh || !triangle || !scan || !surface) { NSLog(@"BorosKit GPU tests: Metal library failed: %@", error); return nullptr; }
    BKGPUMetalAddLibrary(*device, surface);   // 2026-11-26: bk_surface_* (BKSurfacePass)
    id<MTLLibrary> volume = [mtl newLibraryWithSource:BKVolumeShaderSource() options:[BKMetalDevice shaderCompileOptions] error:&error];
    if (!volume) { NSLog(@"BorosKit GPU tests: volume library failed: %@", error); return nullptr; }
    BKGPUMetalAddLibrary(*device, volume);    // 2026-11-26: bk_raycast / bk_brick_* (BKRaycastPass)
    id<MTLLibrary> reformat = [mtl newLibraryWithSource:BKReformatShaderSource() options:[BKMetalDevice shaderCompileOptions] error:&error];
    if (!reformat) { NSLog(@"BorosKit GPU tests: reformat library failed: %@", error); return nullptr; }
    BKGPUMetalAddLibrary(*device, reformat);  // 2026-11-26: bk_curved_reformat (BKReformatPass)
    BKGPUMetalAddLibrary(*device, mesh);
    BKGPUMetalAddLibrary(*device, triangle);
    BKGPUMetalAddLibrary(*device, scan);
    return device;
}

}  // namespace bkshared
