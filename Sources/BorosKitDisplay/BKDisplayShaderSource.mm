// BorosKitDisplay: Metal shader source for 2D image display, compiled at runtime.
//
// Why runtime compilation: same reason as BorosKitRender — `swift build` does not
// reliably compile .metal files, and the app consumes BorosKit as a local package. The
// source is embedded and compiled once per GPU with -[MTLDevice newLibraryWithSource:].
// Objective-C++ only for the readable raw string literal.

#import <Foundation/Foundation.h>
#import "BKDisplayShaderTypes.h"

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
)METAL";

        const char *params = "struct BKDisplayParams { " BKD_STRINGIFY(BK_DISPLAY_PARAMS_FIELDS) " };\n";

        const char *shaders = R"METAL(
struct BKVertexOut {
    float4 position [[position]];
};

// One oversized triangle that covers the whole target; cheaper and simpler than a quad.
vertex BKVertexOut bk_display_vertex(uint vid [[vertex_id]])
{
    float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    BKVertexOut out;
    out.position = float4(p, 0.0, 1.0);
    return out;
}

// Reads one image pixel; coordinates are clamped to the edge (used by bilinear sampling
// at the image border, so edge pixels are not blended with the background).
static float bk_read(texture2d<float, access::read> image, int2 c, constant BKDisplayParams &p)
{
    c = clamp(c, int2(0), int2(int(p.imageWidth) - 1, int(p.imageHeight) - 1));
    return image.read(uint2(c)).r;
}

// One fragment = one device pixel of the view. Find the image point under it with the
// inverse view transform, sample (nearest or bilinear, by hand so it works on every GPU,
// including those that cannot filter 32-bit float textures), then window/level, invert
// and the optional colour table.
fragment float4 bk_display_fragment(BKVertexOut in [[stage_in]],
                                    texture2d<float, access::read> image [[texture(0)]],
                                    texture2d<float, access::read> lut   [[texture(1)]],
                                    constant BKDisplayParams &p          [[buffer(0)]])
{
    float4 background = float4(p.bgR, p.bgG, p.bgB, p.bgA);
    // in.position.xy is the device-pixel centre (x + 0.5, y + 0.5), y down.
    float2 v = in.position.xy / p.scale;
    float2 img = float2(p.m_a * v.x + p.m_c * v.y + p.m_tx,
                        p.m_b * v.x + p.m_d * v.y + p.m_ty);
    if (img.x < 0.0 || img.y < 0.0 || img.x >= p.imageWidth || img.y >= p.imageHeight)
        return background;

    float value;
    if (p.interpolation == 1) {
        // Pixel centres are at i + 0.5.
        float2 f = img - 0.5;
        float2 base = floor(f);
        float2 w = f - base;
        int2 b = int2(base);
        float v00 = bk_read(image, b,              p);
        float v10 = bk_read(image, b + int2(1, 0), p);
        float v01 = bk_read(image, b + int2(0, 1), p);
        float v11 = bk_read(image, b + int2(1, 1), p);
        value = mix(mix(v00, v10, w.x), mix(v01, v11, w.x), w.y);
    } else {
        value = bk_read(image, int2(floor(img)), p);
    }

    float t = (p.windowWidth > 0.0) ? (value - p.windowLower) / p.windowWidth
                                     : (value >= p.windowLower ? 1.0 : 0.0);
    t = clamp(t, 0.0, 1.0);
    if (p.invert != 0)
        t = 1.0 - t;

    if (p.useColorTable != 0) {
        uint index = uint(t * 255.0 + 0.5);
        float4 c = lut.read(uint2(index, 0));
        return float4(c.rgb, 1.0);
    }
    return float4(t, t, t, 1.0);
}
)METAL";

        source = [NSString stringWithFormat:@"%s%s%s", prelude, params, shaders];
    });
    return source;
}
