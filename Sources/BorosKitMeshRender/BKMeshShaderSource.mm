// BorosKitMeshRender: the Metal shader source for drawing meshes, compiled at runtime
// (like the volume shader in BorosKitRender, so no Metal build step is needed in the
// Swift package and the same code works on macOS and iOS).

/* BOROS OVERVIEW (plain language)
 * These are the small programs the graphics chip runs to draw a surface:
 *  - the "vertex" program places every corner of every triangle on the screen, using
 *    exactly the same camera rules as the 3D volume picture, so a mesh and the CT line
 *    up millimetre for millimetre;
 *  - the "fragment" program colours each screen pixel a triangle covers, with the same
 *    simple lighting as the volume picture: a light at the viewer's eye plus a little
 *    ambient light, so surfaces facing you are bright and edges darker.
 * It also records, per pixel, how far along the viewing ray the surface is (in mm),
 * which is what is needed later to blend meshes correctly with the volume.
 */

#import <Foundation/Foundation.h>
#import "BKMeshShaderTypes.h"
#import "BKMeshShaderBodies.h"   // 2026-11-26 (M8): shared Metal / GLSL shader maths

// Returns the full shader source: prelude, the shared uniform struct (from
// BKMeshShaderTypes.h) and the shader functions. extern "C" because the renderer is
// plain Objective-C.
extern "C" NSString *BKMeshShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *prelude = R"METAL(
#include <metal_stdlib>
using namespace metal;
typedef float4   bk_mesh_float4;
typedef float4x4 bk_mesh_float4x4;
// 2026-11-26 (M8): the names the shared bodies (BKMeshShaderBodies.h) use, in Metal.
typedef float2 bk_float2;
typedef float3 bk_float3;
typedef float4 bk_float4;
#define BK_FN static
#define BK_MESH_U_PARAM , constant BKMeshUniforms &u
#define BK_MESH_U_ARG , u
#define bk_dfdx dfdx
#define bk_dfdy dfdy
constant int BKProjPerspective = 1;
)METAL";

        const char *uniforms = "struct BKMeshUniforms { " BK_MESH_STRINGIFY(BK_MESH_UNIFORM_FIELDS) " };\n";

        // The shared bodies (one copy for Metal and Vulkan), pasted in after the uniform struct.
        const char *bodies = BK_MESH_STRINGIFY(BK_MESH_SHADER_VERTEX_BODIES) "\n"
                             BK_MESH_STRINGIFY(BK_MESH_SHADER_FRAGMENT_BODIES) "\n";

        const char *functions = R"METAL(

// Must match BKMeshGPUVertex (10 floats, 40 bytes).
struct BKMeshVertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float4 color;
};

struct BKMeshVaryings {
    // 2026-11-25: invariant - a see-through mesh is drawn twice (depth-only, then colour with
    // "less or equal"), so both passes must compute bit-identical depths (needs
    // MTLCompileOptions.preserveInvariance, set in BKMetalDevice).
    float4 position [[position, invariant]];
    float3 world;       // patient mm
    float3 normal;      // patient space, not normalised yet
    float4 color;
    float2 tcoord;      // 2026-11-14: texture coordinates (0 when the mesh is not textured)
};

// bk_project / bk_view_depth: BKMeshShaderBodies.h (shared with the Vulkan shaders since 2026-11-26).

// 2026-11-14: the vertex work as a plain function, shared by the untextured and textured
// vertex functions (a vertex function can't call another one).
static BKMeshVaryings bk_mesh_vertex_common(device const BKMeshVertexIn *vertices, constant BKMeshUniforms &u, uint vid)
{
    BKMeshVertexIn v = vertices[vid];
    float3 world = (u.model * float4(float3(v.position), 1.0f)).xyz;
    BKMeshVaryings out;
    out.position = bk_project(world, u);
    out.world = world;
    out.normal = (u.normalMatrix * float4(float3(v.normal), 0.0f)).xyz;
    out.color = u.useVertexColors ? float4(v.color) : float4(1.0f);
    out.tcoord = float2(0.0f);
    return out;
}

vertex BKMeshVaryings bk_mesh_vertex(device const BKMeshVertexIn *vertices [[buffer(0)]],
                                     constant BKMeshUniforms &u          [[buffer(1)]],
                                     uint vid                            [[vertex_id]])
{
    return bk_mesh_vertex_common(vertices, u, vid);
}

// 2026-11-14: the same for a textured mesh, plus its texture coordinates (second vertex
// stream: packed float x2 per vertex, see BKMeshShaderTypes.h).
vertex BKMeshVaryings bk_mesh_vertex_textured(device const BKMeshVertexIn *vertices [[buffer(0)]],
                                              constant BKMeshUniforms &u          [[buffer(1)]],
                                              device const packed_float2 *tcoords [[buffer(2)]],
                                              uint vid                            [[vertex_id]])
{
    BKMeshVaryings out = bk_mesh_vertex_common(vertices, u, vid);
    out.tcoord = float2(tcoords[vid]);
    return out;
}

// bk_mesh_shade_straight / bk_mesh_shade: BKMeshShaderBodies.h (shared with Vulkan since 2026-11-26).
// The lit, premultiplied colour of a surface point; the varyings are passed one by one there.

// 2026-11-14: textured surface point = BKMeshTextureModulate(lit colour, texel) (BKMeshDrawCore.h):
// the clamped straight colour times the texel, then premultiplied.
static float4 bk_mesh_shade_textured(BKMeshVaryings in, constant BKMeshUniforms &u,
                                     texture2d<float> tex, sampler smp)
{
    float4 c = clamp(bk_mesh_shade_straight(in.world, in.normal, in.color, u), 0.0f, 1.0f) * tex.sample(smp, in.tcoord);
    return float4(c.rgb * c.a, c.a);
}

// bk_mesh_ray_distance: BKMeshShaderBodies.h (shared with Vulkan since 2026-11-26).

fragment float4 bk_mesh_fragment(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    return bk_mesh_shade(in.world, in.normal, in.color, u);
}

struct BKMeshFragmentOut {
    float4 color [[color(0)]];
    float distance [[color(1)]];
};

// Same as above plus the ray distance in a second (R32Float) target.
fragment BKMeshFragmentOut bk_mesh_fragment_distance(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    BKMeshFragmentOut out;
    out.color = bk_mesh_shade(in.world, in.normal, in.color, u);
    out.distance = bk_mesh_ray_distance(in.world, u);
    return out;
}

// 2026-11-14: textured versions of the two fragment functions above.
fragment float4 bk_mesh_fragment_textured(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]],
                                          texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]])
{
    return bk_mesh_shade_textured(in, u, tex, smp);
}

fragment BKMeshFragmentOut bk_mesh_fragment_distance_textured(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]],
                                                              texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]])
{
    BKMeshFragmentOut out;
    out.color = bk_mesh_shade_textured(in, u, tex, smp);
    out.distance = bk_mesh_ray_distance(in.world, u);
    return out;
}

// ---- Lines -------------------------------------------------------------------------
// Lines (outline boxes, wireframes, label strokes) are drawn as thin screen-aligned
// rectangles: two triangles per segment, `lineHalfWidth` pixels to each side.
// Why not the GPU's own line primitive: it is always 1 pixel wide (Metal) or wide lines
// are an optional feature (Vulkan), so rectangles give the same width on every GPU and
// API. The rectangles are depth-tested like meshes, so a bone surface hides the parts
// of an outline box that lie behind it.

struct BKLineVaryings {
    float4 position [[position]];
    float3 world;       // patient mm (for the ray-distance output)
};

// vid: 6 vertices per segment (two triangles). Corners 0,1,4 sit at the start point,
// 2,3,5 at the end point; 1,4,5 on the left side, 0,2,3 on the right side.
vertex BKLineVaryings bk_line_vertex(device const packed_float3 *points [[buffer(0)]],
                                     constant BKMeshUniforms &u         [[buffer(1)]],
                                     uint vid                           [[vertex_id]])
{
    uint segment = vid / 6, corner = vid % 6;
    float3 a = (u.model * float4(float3(points[segment * 2]), 1.0f)).xyz;
    float3 b = (u.model * float4(float3(points[segment * 2 + 1]), 1.0f)).xyz;
    BKLineVaryings out;
    // Perspective: a segment reaching behind the eye is cut at the near distance first
    // (projecting a point behind the eye would flip it across the screen).
    if (u.projection == BKProjPerspective) {
        float za = bk_view_depth(a, u), zb = bk_view_depth(b, u);
        float zmin = u.nearDistance;
        if (za < zmin && zb < zmin) {               // entirely behind: draw nothing
            out.position = float4(0, 0, 2, 1);
            out.world = a;
            return out;
        }
        if (za < zmin) a = mix(a, b, (zmin - za) / (zb - za));
        else if (zb < zmin) b = mix(b, a, (zmin - zb) / (za - zb));
    }
    float4 ca = bk_project(a, u), cb = bk_project(b, u);
    float2 halfViewport = 0.5f * float2(max(u.viewportWidth, 1.0f), max(u.viewportHeight, 1.0f));
    float2 sa = ca.xy / ca.w * halfViewport, sb = cb.xy / cb.w * halfViewport;   // pixels
    float2 d = sb - sa;
    d = length(d) > 1e-6f ? normalize(d) : float2(1, 0);
    float2 normal = float2(-d.y, d.x);
    bool atEnd = (corner == 2 || corner == 3 || corner == 5);
    float side = (corner == 1 || corner == 4 || corner == 5) ? 1.0f : -1.0f;
    float4 p = atEnd ? cb : ca;
    p.xy += normal * side * u.lineHalfWidth / halfViewport * p.w;   // pixels -> clip space
    out.position = p;
    out.world = atEnd ? b : a;
    return out;
}

fragment float4 bk_line_fragment(BKLineVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    float alpha = clamp(u.color.a, 0.0f, 1.0f);
    return float4(clamp(u.color.rgb, 0.0f, 1.0f) * alpha, alpha);   // premultiplied
}

fragment BKMeshFragmentOut bk_line_fragment_distance(BKLineVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    BKMeshFragmentOut out;
    float alpha = clamp(u.color.a, 0.0f, 1.0f);
    out.color = float4(clamp(u.color.rgb, 0.0f, 1.0f) * alpha, alpha);
    float3 rel = in.world - u.cameraPosition.xyz;
    out.distance = (u.projection == BKProjPerspective) ? length(rel) : dot(rel, u.cameraForward.xyz);
    return out;
}

// ---- Points (2026-11-14) -------------------------------------------------------------
// Each point is a square of 2 * lineHalfWidth pixels centred on its projected position
// (BKMeshPointSquare in BKMeshDrawCore.h): 6 vertices = two triangles per point. Drawn with
// the line fragment functions (flat colour, optional ray distance).
vertex BKLineVaryings bk_point_vertex(device const packed_float3 *points [[buffer(0)]],
                                      constant BKMeshUniforms &u         [[buffer(1)]],
                                      uint vid                           [[vertex_id]])
{
    uint index = vid / 6, corner = vid % 6;
    float3 p = (u.model * float4(float3(points[index]), 1.0f)).xyz;
    BKLineVaryings out;
    out.world = p;
    // Perspective: a point behind the near distance is not drawn (it would flip across the screen).
    if (u.projection == BKProjPerspective && bk_view_depth(p, u) < u.nearDistance) {
        out.position = float4(0, 0, 2, 1);
        return out;
    }
    float4 c = bk_project(p, u);
    float2 halfViewport = 0.5f * float2(max(u.viewportWidth, 1.0f), max(u.viewportHeight, 1.0f));
    // Corners: 0 (-,-) 1 (+,-) 2 (+,+) | 3 (-,-) 4 (+,+) 5 (-,+)
    float sx = (corner == 1 || corner == 2 || corner == 4) ? 1.0f : -1.0f;
    float sy = (corner == 2 || corner == 4 || corner == 5) ? 1.0f : -1.0f;
    c.xy += float2(sx, sy) * u.lineHalfWidth / halfViewport * c.w;   // pixels -> clip space
    out.position = c;
    return out;
}

// Writes the GPU's idea of sizeof(BKMeshUniforms) (test: CPU and GPU must agree).
kernel void bk_mesh_uniforms_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKMeshUniforms);
}
)METAL";

        source = [NSString stringWithFormat:@"%s%s%s%s", prelude, uniforms, bodies, functions];
    });
    return source;
}
