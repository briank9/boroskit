// BorosKitDisplay: BKOverlayShaderSource.mm - the Metal source of the 2D overlay engine's shaders (moved out of
// BKOverlayRenderer.mm on 2026-11-26 so test programs can compile it without the Objective-C class).
//
// Original BorosKit code written for this project; contains no third-party code.
// The maths is BKOverlayShaderBodies.h (shared with Vulkan, option C); here the Metal names and the thin entry points.
// Bindings (BKOverlayPass): vertex buffer 0 = vertices, buffer 1 = params (vertex and fragment), texture 0 + sampler 0.

#import <Foundation/Foundation.h>
#include "BKOverlayCore.h"
#include "BKOverlayShaderBodies.h"

#define BKO_STR_(...) #__VA_ARGS__
#define BKO_STR(...) BKO_STR_(__VA_ARGS__)

extern "C" NSString *BKOverlayShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *head = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct BKOverlayVertexIn {          // = BKOverlayVertex (32 bytes)
    float2 position;
    float2 uv;
    float4 color;
};
#define bk_float2 float2
#define bk_float4 float4
#define bko_texture2d texture2d<float>
#define bko_sampler sampler
#define BKO_SAMPLE(t, s, uv) (t).sample(s, uv)
#define BKO_P_PARAM , constant BKOverlayParams &p
#define BKO_P_ARG , p
#define BKO_FN static
)METAL";
        // The names the shared field list uses, in Metal (C: BKGPUTypes.h / <stdint.h>).
        const char *params = "typedef int int32_t;\n"
                             "struct BKOverlayParams { " BKO_STR(BK_OVERLAY_PARAMS_FIELDS) " };\n";
        const char *bodies = BKO_STR(BK_OVERLAY_BODIES) "\n";
        const char *entries = R"METAL(
struct BKOverlayVaryings {
    float4 position [[position]];
    float2 uv;
    float4 color;
};
vertex BKOverlayVaryings bk_overlay_vertex(const device BKOverlayVertexIn *vertices [[buffer(0)]],
                                           constant BKOverlayParams &p [[buffer(1)]],
                                           uint vid [[vertex_id]])
{
    BKOverlayVertexIn v = vertices[vid];
    BKOverlayVaryings o;
    o.position = bk_overlay_clip(v.position, p);
    o.uv = v.uv;
    o.color = v.color;
    return o;
}
fragment float4 bk_overlay_fragment(BKOverlayVaryings in [[stage_in]],
                                    constant BKOverlayParams &p [[buffer(1)]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler smp [[sampler(0)]])
{
    return bk_overlay_shade(in.color, in.uv, image, smp, p);
}
)METAL";
        source = [NSString stringWithFormat:@"%s%s%s%s", head, params, bodies, entries];
    });
    return source;
}
