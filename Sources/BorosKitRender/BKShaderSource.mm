// BorosKitRender: the Metal shader source, compiled at runtime.
//
// Why runtime compilation instead of a prebuilt .metallib: a Swift package built with
// `swift build` does not reliably compile .metal files, and the app may consume
// BorosKit as a local package, a submodule or an Xcode project. Embedding the source
// and compiling it with -[MTLDevice newLibraryWithSource:] works identically in all of
// those, on macOS and iOS. Cost: a one-time compile (tens of milliseconds) when the
// first renderer is created; the compiled library is cached per device.
//
// This file is Objective-C++ only so the shader can be written as a readable C++ raw
// string literal (R"( ... )") with real line numbers in compiler messages.

/* BOROS OVERVIEW (plain language)
 * This file holds the drawing program for the graphics chip. The program is a set of
 * instructions that works out the colour of each pixel in the 3D picture by following
 * an imaginary ray through the scan and combining what it passes through.
 * The program is stored as text inside this file and compiled the first time a
 * renderer starts, which works the same on Mac and iPad. The text must be edited
 * with care because it is code, even though it sits inside a string.
 */

#import <Foundation/Foundation.h>
#import "BKShaderTypes.h"
#import "BKRaycastShaderBodies.h"   // 2026-11-26: the ray caster, shared with the Vulkan GLSL kernels (option C)

// The shared text in source order (helpers, grey trace, colour / fusion helpers and trace, embedded objects).
#define BK_RAYCAST_SHARED_TEXT \
    BK_STRINGIFY(BK_RAYCAST_HELPER_BODIES) "\n" BK_STRINGIFY(BK_RAYCAST_TRACE_BODY) "\n" \
    BK_STRINGIFY(BK_RAYCAST_COLOR_BODIES) "\n" BK_STRINGIFY(BK_RAYCAST_TRACE_EXT_BODY) "\n" \
    BK_STRINGIFY(BK_RAYCAST_GEOMETRY_BODY) "\n"

// Returns the full shader source: a small prelude, the shared parameter struct (from
// BKShaderTypes.h, so CPU and GPU can never disagree), and the kernels.
// extern "C": this file is Objective-C++, but the renderer (plain Objective-C) calls
// this function, so it must not get a C++ mangled name.
extern "C" NSString *BKVolumeShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *prelude = R"METAL(
#include <metal_stdlib>
using namespace metal;
typedef float4   bk_float4;
// 2026-11-26: the shared-subset names of BKRaycastShaderBodies.h, in Metal (GLSL: bk_raycast_common.glsl).
#define bk_float2 float2
#define bk_float3 float3
#define bk_int3 int3
#define bk_uint2 uint2
#define bk_uint3 uint3
#define bk_uint4 uint4
#define bk_float3x3 float3x3
#define bk_texture2d texture2d<float>
#define bk_texture3d texture3d<float>
#define bk_sampler sampler
#define BK_TEX2_READ(t, c) (t).read(c)
#define BK_TEX3_READ(t, c) (t).read(c)
#define BK_TEX2_SAMPLE(t, s, c) (t).sample(s, c)
#define BK_TEX3_SAMPLE(t, s, c) (t).sample(s, c)
#define BK_TEX2_WIDTH(t) (t).get_width()
#define BK_TEX2_HEIGHT(t) (t).get_height()
#define BK_INF INFINITY
#define bk_fabs fabs
#define bk_rint rint
#define bk_all_ge(a, b) all((a) >= (b))
#define bk_all_le(a, b) all((a) <= (b))
#define bk_any_ge(a, b) any((a) >= (b))
#define BK_FN static
#define BK_OUT(T, n) thread T &n
#define BK_INOUT(T, n) thread T &n
#define BK_P_PARAM , constant BKRenderParams &p
#define BK_P_ARG , p
#define BK_P_ONLY_PARAM constant BKRenderParams &p
#define BK_P_ONLY_ARG p
#define BK_P_PARAM_FIRST constant BKRenderParams &p,
#define BK_P_ARG_FIRST p,
#define BK_BRICK_PARAM , device const uint *brickEmpty, device const uint *brickRange
#define BK_BRICK_ARG , brickEmpty, brickRange
#define BK_TRACE_SAMPLERS constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge); constexpr sampler tfSampler(coord::normalized, filter::linear, address::clamp_to_edge);
)METAL";

        const char *params = "struct BKRenderParams { " BK_STRINGIFY(BK_RENDER_PARAMS_FIELDS) " };\n"
                             // Brick size and lookup-table size, from the same header as the CPU side.
                             "constant int BKBrickSize = " BK_STRINGIFY(BK_BRICK_SIZE) ";\n"
                             "constant int BKTransferFunctionEntries = " BK_STRINGIFY(BK_TRANSFER_FUNCTION_ENTRIES) ";\n"
                             "constant int BKMaxClipPlanes = " BK_STRINGIFY(BK_MAX_CLIP_PLANES) ";\n";

        const char *kernels = R"METAL(
// Render modes / projections (must match BKRenderMode / BKProjection in BKVolumeRenderer.h).
constant int BKModeComposite = 0;
constant int BKModeMIP       = 1;
constant int BKModeMinIP     = 2;
constant int BKModeAverage   = 3;
constant int BKProjPerspective = 1;

// 2026-11-26 (agent "vulkan-engine", Vulkan plan 7.1 #4b): the helpers and traces now live in
// BKRaycastShaderBodies.h, shared with the Vulkan GLSL kernels; pasted in below.
)METAL" BK_RAYCAST_SHARED_TEXT R"METAL(
// One thread = one output pixel, written to CPU-readable buffers (8-bit RGBA + float).
// Used by -renderWithWidth:height:error: (exports, MPR slabs, tests). Body: BK_RAYCAST_KERNEL_BODY (shared).
kernel void bk_raycast(texture3d<float> volume       [[texture(0)]],
                       texture2d<float> transferFn   [[texture(1)]],
                       constant BKRenderParams &p    [[buffer(0)]],
                       device uint   *colorOut       [[buffer(1)]],   /* RGBA8 packed in one word */
                       device float  *valueOut       [[buffer(2)]],
                       device const uint *brickEmpty    [[buffer(3)]],   /* 1 word per brick */
                       device const uint *brickRange    [[buffer(4)]],   /* lowest | highest << 16 */
                       texture2d<float> geometryColor    [[texture(3)]],  /* embedded objects (p.useGeometry) */
                       texture2d<float> geometryDistance [[texture(4)]],
                       texture3d<float> blendVolume      [[texture(5)]],  /* fused scan (p.useBlend; placeholder otherwise) */
                       texture2d<float> blendFn          [[texture(6)]],  /* fused scan's colour / opacity table */
                       uint2 gid                     [[thread_position_in_grid]])
{
)METAL" BK_STRINGIFY(BK_RAYCAST_KERNEL_BODY) R"METAL(
}

// One thread = one output pixel, written straight into a GPU texture (e.g. the screen's
// drawable) so the 3D view never copies pixels back to the CPU. The colour is laid over
// an opaque background colour, so the result can be shown as is. (Metal-only entry point: the
// Vulkan on-screen path is planned as storage image + copy, audit finding 5.)
kernel void bk_raycast_texture(texture3d<float> volume                      [[texture(0)]],
                               texture2d<float> transferFn                  [[texture(1)]],
                               texture2d<float, access::write> target       [[texture(2)]],
                               constant BKRenderParams &p                   [[buffer(0)]],
                               constant float4 &background                  [[buffer(1)]],
                               device const uint *brickEmpty                [[buffer(2)]],
                               device const uint *brickRange                [[buffer(3)]],
                               texture2d<float> geometryColor               [[texture(3)]],  /* embedded objects (p.useGeometry) */
                               texture2d<float> geometryDistance            [[texture(4)]],
                               texture3d<float> blendVolume                 [[texture(5)]],  /* fused scan (p.useBlend) */
                               texture2d<float> blendFn                     [[texture(6)]],
                               uint2 gid                                    [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    float geomT; float4 geomColor;
    bk_geometry_at(p, gid, geometryColor, geometryDistance, geomT, geomColor);
    BKTraceResult r = (p.colorVolume != 0 || p.useBlend != 0)
        ? bk_trace_ext(volume, transferFn, blendVolume, blendFn, p, gid, geomT, geomColor)   /* colour / fusion (2026-11-24) */
        : bk_trace(volume, transferFn, p, gid, brickEmpty, brickRange, geomT, geomColor);
    float3 rgb = r.color.rgb + (1.0f - r.color.a) * background.rgb;  // colour is premultiplied
    target.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}

// Scales a (low-resolution) image up to the size of `target` with linear filtering.
// Used while the user rotates or zooms: the 3D image is ray-cast at reduced resolution
// for speed, then stretched to fill the view (Horos does the same with its LOD setting).
kernel void bk_upscale(texture2d<float> source                 [[texture(0)]],
                       texture2d<float, access::write> target  [[texture(1)]],
                       uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(target.get_width(), target.get_height());
    target.write(source.sample(s, uv), gid);
}

// Empty-space skipping, step 1 (once per volume): one thread per brick finds the
// lowest and highest stored value in the brick PLUS one voxel on every side. The extra
// voxel matters: a sample just inside the brick's edge blends in its neighbours, so
// they must count as part of the brick, or a brick could wrongly look empty.
// Values are kept as the raw 16-bit numbers, exactly as stored in the volume.
kernel void bk_brick_ranges(texture3d<float> volume      [[texture(0)]],
                            device uint *brickRange      [[buffer(0)]],   /* lowest | highest << 16 */
                            constant uint4 &grid4        [[buffer(1)]],   /* xyz = brick counts (uint4: no 3-vectors in GPU buffers) */
                            uint3 gid                    [[thread_position_in_grid]])
{
    int3 volumeSize3 = int3(volume.get_width(), volume.get_height(), volume.get_depth());
)METAL" BK_STRINGIFY(BK_BRICK_RANGES_BODY) R"METAL(
}

// Empty-space skipping, step 2 (whenever the colour/opacity rule changes): one thread
// per brick decides whether the brick is completely see-through, i.e. every lookup-
// table entry the ray could possibly read for a value in the brick's range has zero
// opacity. Mirrors the ray's own lookup (same value scaling, same table position) and
// adds one table entry of margin on each side for the table's linear blending and for
// rounding. alphaCount[k] = how many of the first k table entries are not see-through,
// so "any opaque entry between a and b" is a single subtraction.
kernel void bk_classify_bricks(device const uint *brickRange     [[buffer(0)]],
                               device const uint *alphaCount    [[buffer(1)]],
                               device uint *brickEmpty          [[buffer(2)]],
                               constant BKRenderParams &p       [[buffer(3)]],
                               uint3 gid                        [[thread_position_in_grid]])
{
)METAL" BK_STRINGIFY(BK_CLASSIFY_BRICKS_BODY) R"METAL(
}

// Test helper: reports the size of the parameter block as the GPU sees it, so a unit
// test can prove the CPU and GPU layouts are identical.
kernel void bk_params_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKRenderParams);
}
)METAL";

        source = [NSString stringWithFormat:@"%s%s%s", prelude, params, kernels];
    });
    return source;
}
