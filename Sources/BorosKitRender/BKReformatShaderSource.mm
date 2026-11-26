// BorosKitRender: BKReformatShaderSource.mm - the Metal source of the curved reformat kernel (moved out of
// BKCurvedReformat.mm on 2026-11-26 so test programs can compile it without the Objective-C class).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <Foundation/Foundation.h>
#import "BKCurvedReformatCore.h"
#import "BKReformatShaderBodies.h"   // 2026-11-26: the kernel, shared with Vulkan (option C)

#define BKR_STR2(...) #__VA_ARGS__
#define BKR_STR(...) BKR_STR2(__VA_ARGS__)

// The kernel. Metal -> GLSL: `kernel` + [[thread_position_in_grid]] -> compute shader + gl_GlobalInvocationID;
// `constant BKReformatParams &` -> layout(std430) readonly buffer (or uniform block); `device const float4 *`
// -> std430 readonly buffer of vec4; `texture3d<float, access::read>.read(uint3)` -> texelFetch(sampler3D, ivec3, 0)
// (R16_UNORM, normalised 0..1); `device float *` -> std430 writeonly buffer of float; int(float) truncates
// toward zero in both.
extern "C" NSString *BKReformatShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *header =
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "typedef uint uint32_t;\n"
            "typedef int int32_t;\n"
            "struct BKReformatParams { " BKR_STR(BK_REFORMAT_PARAMS_FIELDS) " };\n";
        // 2026-11-26 (Vulkan plan 7.1 #5): the maths is BKReformatShaderBodies.h (shared with the Vulkan GLSL
        // kernel); here only the Metal names of the shared subset and the thin entry point.
        const char *body =
            "#define bk_float3 float3\n#define bk_float4 float4\n#define bk_int3 int3\n"
            "#define bkr_texture3d texture3d<float, access::read>\n"
            "#define BKR_READ(t, x, y, z) (t).read(uint3(x, y, z)).r\n"
            "#define BKR_P_PARAM , constant BKReformatParams &p\n#define BKR_P_ARG , p\n"
            "#define BKR_P_FIRST_PARAM constant BKReformatParams &p,\n#define BKR_P_FIRST_ARG p,\n"
            "#define BKR_OUT4(name) thread float *name\n#define BKR_FN static\n"
            BKR_STR(BK_REFORMAT_HELPER_BODIES) "\n"
            "kernel void bk_curved_reformat(texture3d<float, access::read> vol [[texture(0)]],\n"
            "                               constant BKReformatParams &p [[buffer(0)]],\n"
            "                               device const float4 *frames [[buffer(1)]],\n"
            "                               device float *outValues [[buffer(2)]],\n"
            "                               uint2 gid [[thread_position_in_grid]])\n"
            "{\n" BKR_STR(BK_REFORMAT_KERNEL_BODY) "\n}\n";
        source = [[NSString stringWithUTF8String:header] stringByAppendingString:[NSString stringWithUTF8String:body]];
    });
    return source;
}

