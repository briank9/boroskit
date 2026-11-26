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
 * ONE SOURCE (2026-11-26, agent "vulkan-engine"): the kernel maths now lives in BKSurfaceShaderBodies.h,
 * shared with the Vulkan GLSL kernels; this file only adds the Metal names and the thin entry points.
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
#import "BKSurfaceShaderBodies.h"   // 2026-11-26: the kernels, shared with Vulkan (option C)

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

        // 2026-11-26 (agent "vulkan-engine", shader option C): the names the shared bodies use, in Metal. The
        // maths itself is in BKSurfaceShaderBodies.h (also #included by the Vulkan GLSL kernels).
        const char *subset = R"METAL(
#define bk_uint3 uint3
#define bk_float3 float3
#define bk_float4 float4
#define bk_float3x3 float3x3
#define bk_float4x4 float4x4
#define bk_rint rint
#define bk_popcount popcount
#define bk_barrier() threadgroup_barrier(mem_flags::mem_threadgroup)
#define BK_FN static
#define BK_OUT_UINT(name) thread uint &name
#define BK_SURF_PARAM , constant BKSurfaceParams &P, device const uint *fieldWords, texture3d<float> volume, sampler linearSampler
#define BK_SURF_ARG , P, fieldWords, volume, linearSampler
#define BK_SCAN_PARAM , threadgroup uint *bkScratch
#define BK_SCAN_ARG , bkScratch
#define BK_READ16(words, i) (((words)[(i) >> 1] >> (((i) & 1u) * 16u)) & 0xffffu)
#define BK_VOLUME_READ(p) volume.read(p).r
#define BK_VOLUME_SAMPLE(c) volume.sample(linearSampler, c).r
)METAL";
        const char *helpers = BK_SURFACE_STRINGIFY(BK_SURFACE_HELPER_BODIES) "\n";

        // Thin entry points: the resources under the shared names, then the shared body.
        const char *functions =
            "kernel void bk_surface_sample(constant BKSurfaceParams &P [[buffer(0)]], device uint *fieldWords [[buffer(1)]],\n"
            "    texture3d<float> volume [[texture(0)]], sampler linearSampler [[sampler(0)]], uint3 gid [[thread_position_in_grid]])\n"
            "{\n" BK_SURFACE_STRINGIFY(BK_SURFACE_SAMPLE_BODY) "\n}\n"
            "kernel void bk_surface_blur(constant BKSurfaceParams &P [[buffer(0)]], device const uint *fieldWords [[buffer(1)]],\n"
            "    device uint *blurOut [[buffer(2)]], texture3d<float> volume [[texture(0)]], sampler linearSampler [[sampler(0)]],\n"
            "    uint3 gid [[thread_position_in_grid]])\n"
            "{\n" BK_SURFACE_STRINGIFY(BK_SURFACE_BLUR_BODY) "\n}\n"
            "kernel void bk_surface_classify(constant BKSurfaceParams &P [[buffer(0)]], device const uint *fieldWords [[buffer(1)]],\n"
            "    device uint *packedWords [[buffer(2)]], device uint *rowVertexWords [[buffer(3)]], device uint *rowTriangleWords [[buffer(4)]],\n"
            "    device const uint *tableWords [[buffer(5)]], texture3d<float> volume [[texture(0)]], sampler linearSampler [[sampler(0)]],\n"
            "    uint3 group [[threadgroup_position_in_grid]], uint3 local [[thread_position_in_threadgroup]],\n"
            "    uint3 groupSize [[threads_per_threadgroup]])\n"
            "{\n"
            "    const uint lid = local.x, n = groupSize.x;\n"
            "    threadgroup uint bkScratch[BK_SURFACE_ROW_THREADS];\n"
            "    threadgroup uint bkValues16[BK_SURFACE_ROW_THREADS];\n"
            BK_SURFACE_STRINGIFY(BK_SURFACE_CLASSIFY_BODY) "\n}\n"
            "kernel void bk_surface_emit(constant BKSurfaceParams &P [[buffer(0)]], device const uint *fieldWords [[buffer(1)]],\n"
            "    device const uint *packedWords [[buffer(2)]], device const uint *rowVertexWords [[buffer(3)]],\n"
            "    device const uint *rowTriangleWords [[buffer(4)]], device const uint *tableWords [[buffer(5)]],\n"
            "    device float4 *positionsOut [[buffer(6)]], device float4 *normalsOut [[buffer(7)]], device uint *indexWords [[buffer(8)]],\n"
            "    texture3d<float> volume [[texture(0)]], sampler linearSampler [[sampler(0)]],\n"
            "    uint3 group [[threadgroup_position_in_grid]], uint3 local [[thread_position_in_threadgroup]],\n"
            "    uint3 groupSize [[threads_per_threadgroup]])\n"
            "{\n"
            "    const uint lid = local.x, n = groupSize.x;\n"
            "    threadgroup uint bkScratch[BK_SURFACE_ROW_THREADS];\n"
            BK_SURFACE_STRINGIFY(BK_SURFACE_EMIT_BODY) "\n}\n"
            R"METAL(
// Test helper: lets a unit test check that C and the GPU agree on the struct size.
kernel void bk_surface_params_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKSurfaceParams);
}
)METAL";
        source = [NSString stringWithFormat:@"%@%@%s%s%s", prelude, params, subset, helpers, functions];
    });
    return source;
}
