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
)METAL";

        const char *uniforms = "struct BKMeshUniforms { " BK_MESH_STRINGIFY(BK_MESH_UNIFORM_FIELDS) " };\n";

        const char *functions = R"METAL(
constant int BKProjPerspective = 1;

// Must match BKMeshGPUVertex (10 floats, 40 bytes).
struct BKMeshVertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float4 color;
};

struct BKMeshVaryings {
    float4 position [[position]];
    float3 world;       // patient mm
    float3 normal;      // patient space, not normalised yet
    float4 color;
};

// Places one vertex on screen with the SAME camera model as the volume ray caster:
// a pixel's ray there is cameraPosition + right*x + up*y (+ forward*t). Working in
// camera coordinates (x right, y up, z = distance along the view direction):
//   orthographic: screen = (x / halfWidth, y / halfHeight)
//   perspective : screen = (x / z / tan(half angle), y / z / tan(half angle))
vertex BKMeshVaryings bk_mesh_vertex(device const BKMeshVertexIn *vertices [[buffer(0)]],
                                     constant BKMeshUniforms &u          [[buffer(1)]],
                                     uint vid                            [[vertex_id]])
{
    BKMeshVertexIn v = vertices[vid];
    float3 world = (u.model * float4(float3(v.position), 1.0f)).xyz;
    float3 rel = world - u.cameraPosition.xyz;
    float x = dot(rel, u.cameraRight.xyz);
    float y = dot(rel, u.cameraUp.xyz);
    float z = dot(rel, u.cameraForward.xyz);
    float range = max(u.farDistance - u.nearDistance, 1e-6f);
    BKMeshVaryings out;
    if (u.projection == BKProjPerspective) {
        // Depth 0 at the near distance, 1 at the far distance (after the divide by z).
        out.position = float4(x / u.halfWidth, y / u.halfHeight,
                              u.farDistance * (z - u.nearDistance) / range, z);
    } else {
        out.position = float4(x / u.halfWidth, y / u.halfHeight, (z - u.nearDistance) / range, 1.0f);
    }
    out.world = world;
    out.normal = (u.normalMatrix * float4(float3(v.normal), 0.0f)).xyz;
    out.color = u.useVertexColors ? float4(v.color) : float4(1.0f);
    return out;
}

// The lit, premultiplied colour of a surface point. Lighting = the volume renderer's:
// ambient + diffuse * cos + specular * cos^power, with the light at the viewer and
// |cos| so both sides of a surface are lit (STL files often have mixed-up sides).
static float4 bk_mesh_shade(BKMeshVaryings in, constant BKMeshUniforms &u)
{
    float3 n = in.normal;
    if (!u.hasNormals || length(n) < 1e-6f) {
        // No normals in the mesh: use the triangle's own direction (flat facets),
        // from how the position changes between neighbouring pixels.
        n = cross(dfdx(in.world), dfdy(in.world));
    }
    float len = length(n);
    float3 toViewer = (u.projection == BKProjPerspective) ? normalize(u.cameraPosition.xyz - in.world)
                                                          : -u.cameraForward.xyz;
    float ndl = len > 1e-12f ? fabs(dot(n / len, toViewer)) : 1.0f;
    float3 base = in.color.rgb * u.color.rgb;
    float3 rgb = base * (u.ambient + u.diffuse * ndl) + u.specular * pow(ndl, u.specularPower);
    float alpha = clamp(u.color.a * in.color.a, 0.0f, 1.0f);
    return float4(clamp(rgb, 0.0f, 1.0f) * alpha, alpha);   // premultiplied, like the volume output
}

// Distance (mm) along the viewing ray from the camera to this surface point, measured
// the way the volume ray caster measures its ray parameter t.
static float bk_mesh_ray_distance(BKMeshVaryings in, constant BKMeshUniforms &u)
{
    float3 rel = in.world - u.cameraPosition.xyz;
    return (u.projection == BKProjPerspective) ? length(rel) : dot(rel, u.cameraForward.xyz);
}

fragment float4 bk_mesh_fragment(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    return bk_mesh_shade(in, u);
}

struct BKMeshFragmentOut {
    float4 color [[color(0)]];
    float distance [[color(1)]];
};

// Same as above plus the ray distance in a second (R32Float) target.
fragment BKMeshFragmentOut bk_mesh_fragment_distance(BKMeshVaryings in [[stage_in]], constant BKMeshUniforms &u [[buffer(1)]])
{
    BKMeshFragmentOut out;
    out.color = bk_mesh_shade(in, u);
    out.distance = bk_mesh_ray_distance(in, u);
    return out;
}

// Writes the GPU's idea of sizeof(BKMeshUniforms) (test: CPU and GPU must agree).
kernel void bk_mesh_uniforms_size(device uint *out [[buffer(0)]])
{
    out[0] = sizeof(BKMeshUniforms);
}
)METAL";

        source = [NSString stringWithFormat:@"%s%s%s", prelude, uniforms, functions];
    });
    return source;
}
