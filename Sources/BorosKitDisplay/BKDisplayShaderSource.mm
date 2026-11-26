// BorosKitDisplay: Metal shader source for 2D image display, compiled at runtime.
//
// Why runtime compilation: same reason as BorosKitRender — `swift build` does not
// reliably compile .metal files, and the app consumes BorosKit as a local package. The
// source is embedded and compiled once per GPU with -[MTLDevice newLibraryWithSource:].
// Objective-C++ only for the readable raw string literal.

/* BOROS OVERVIEW (plain language)
 * This file holds the small programs (called shaders) that run on the graphics chip
 * to paint the 2D CT picture.
 * They take each pixel's number, apply the brightness and contrast setting, look up
 * its colour, and handle zoom, pan, rotation and flip. Running this on the graphics
 * chip keeps scrolling and adjusting fast, instead of loading the processor.
 * The code is stored as text inside this file and compiled on first use. The
 * clinician never sees it directly; only the image renderer uses it.
 */

#import <Foundation/Foundation.h>
#import "BKDisplayShaderTypes.h"
#import "BKDisplayShaderBodies.h"   // 2026-11-26: shared with Vulkan (option C)

// What: returns the full shader source (prelude + shared parameter struct + shaders).
// Why extern "C": the renderer is plain Objective-C and must link to an unmangled name.
extern "C" NSString *BKDisplayShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *prelude = R"METAL(
#include <metal_stdlib>
using namespace metal;
typedef int bk_i32;
)METAL";

        const char *params = "struct BKDisplayParams { " BKD_STRINGIFY(BK_DISPLAY_PARAMS_FIELDS) " };\n";

        // 2026-11-26 (Vulkan plan 7.1 #6): the maths is BKDisplayShaderBodies.h (shared with the Vulkan GLSL);
        // here the Metal names of the shared subset and the thin entry points.
        const char *shaders =
            "#define bk_float2 float2\n#define bk_float4 float4\n#define bk_int2 int2\n#define bk_uint2 uint2\n"
            "#define bkd_texture2d texture2d<float, access::read>\n"
            "#define BKD_READ(t, c) (t).read(uint2(c))\n"
            "#define BKD_P_PARAM , constant BKDisplayParams &p\n#define BKD_P_ARG , p\n#define BKD_FN static\n"
            BKD_STRINGIFY(BK_DISPLAY_BODIES) "\n"
            "struct BKVertexOut { float4 position [[position]]; };\n"
            "vertex BKVertexOut bk_display_vertex(uint vid [[vertex_id]])\n"
            "{\n    float2 p = " BKD_STRINGIFY(BK_DISPLAY_TRIANGLE(vid)) ";\n"
            "    BKVertexOut out;\n    out.position = float4(p, 0.0, 1.0);\n    return out;\n}\n"
            "fragment float4 bk_display_fragment(BKVertexOut in [[stage_in]],\n"
            "                                    texture2d<float, access::read> image [[texture(0)]],\n"
            "                                    texture2d<float, access::read> lut   [[texture(1)]],\n"
            "                                    constant BKDisplayParams &p          [[buffer(0)]])\n"
            "{\n    return bk_display_shade(in.position.xy, image, lut, p);\n}\n";

        source = [NSString stringWithFormat:@"%s%s%s", prelude, params, shaders];
    });
    return source;
}
