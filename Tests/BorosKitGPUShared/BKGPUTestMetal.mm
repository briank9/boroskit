// BorosKit GPU tests: see BKGPUTestMetal.h.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
#import "BKGPUTestMetal.h"
#import "BKGPUMetal.h"
#import "BKMetalDevice.h"

extern "C" NSString *BKMeshShaderSource(void);   // BorosKitMeshRender/BKMeshShaderSource.mm

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
    if (!mesh || !triangle) { NSLog(@"BorosKit GPU tests: Metal library failed: %@", error); return nullptr; }
    BKGPUMetalAddLibrary(*device, mesh);
    BKGPUMetalAddLibrary(*device, triangle);
    return device;
}

}  // namespace bkshared
