// BorosKitMeshRender: BKMeshShaderBodies.h - the mesh shader maths written ONCE for Metal and Vulkan.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M8, shader option C = user decision D7): the bodies were
// moved here from BKMeshShaderSource.mm, operation for operation, so the Metal pictures stay identical.
//
// PORTING NOTES (Vulkan / other backends):
//   - Only #defines, read by Metal (BKMeshShaderSource.mm pastes the text in with BK_MESH_STRINGIFY) and by
//     GLSL (Sources/BorosKitGPUVulkan/Shaders/*.vert|frag #include this file, glslc -I). Never compiled as C.
//   - Written in the shared subset (VULKAN-PORT-PLAN.md section 7): types only as bk_float2/3/4; the uniform
//     block reached as `u` through BK_MESH_U_PARAM / BK_MESH_U_ARG (Metal: an extra `constant
//     BKMeshUniforms &u` parameter; GLSL: the global uniform block instance `u`, so both macros are empty);
//     BK_FN = `static` in Metal, nothing in GLSL; derivatives as bk_dfdx / bk_dfdy; ints compared with != 0
//     (GLSL has no int -> bool); built-ins with the same meaning in both: dot cross length normalize max
//     clamp pow abs. Each language's prelude defines these names (Metal: BKMeshShaderSource.mm; GLSL:
//     Shaders/bk_prelude.glsl) plus the constant BKProjPerspective = 1.
//   - Two parts, because GLSL vertex shaders may not use derivatives: the VERTEX part (projection, view
//     depth) and the FRAGMENT part (shading, ray distance). Metal pastes both.
//
// Plain language: the formulas that place a surface point on the screen and colour it, written in one
// place so the Mac engine (Metal) and the Windows / Linux engine (Vulkan) cannot drift apart.

#ifndef BK_MESH_SHADER_BODIES_H
#define BK_MESH_SHADER_BODIES_H

// Places a patient-space point on screen with the SAME camera model as the volume ray caster: a pixel's
// ray is cameraPosition + right*x + up*y (+ forward*t). Camera coordinates: x right, y up, z = distance
// along the view direction. Orthographic: (x / halfWidth, y / halfHeight); perspective: divided by z.
// Depth 0 at the near distance, 1 at the far distance. bk_view_depth: camera z of a point.
#define BK_MESH_SHADER_VERTEX_BODIES \
BK_FN bk_float4 bk_project(bk_float3 world BK_MESH_U_PARAM) \
{ \
    bk_float3 rel = world - u.cameraPosition.xyz; \
    float x = dot(rel, u.cameraRight.xyz); \
    float y = dot(rel, u.cameraUp.xyz); \
    float z = dot(rel, u.cameraForward.xyz); \
    float range = max(u.farDistance - u.nearDistance, 1e-6f); \
    if (u.projection == BKProjPerspective) { \
        return bk_float4(x / u.halfWidth, y / u.halfHeight, u.farDistance * (z - u.nearDistance) / range, z); \
    } \
    return bk_float4(x / u.halfWidth, y / u.halfHeight, (z - u.nearDistance) / range, 1.0f); \
} \
BK_FN float bk_view_depth(bk_float3 world BK_MESH_U_PARAM) \
{ \
    return dot(world - u.cameraPosition.xyz, u.cameraForward.xyz); \
}

// Shading = the volume renderer's: ambient + diffuse * cos + specular * cos^power, light at the viewer,
// |cos| so both sides are lit; no normals -> the triangle's own direction from screen derivatives (flat
// facets). Straight (not premultiplied) colour first, so a texture can be applied in between (VTK's order).
// Ray distance = mm from the camera along the viewing ray, measured like the volume ray caster's t.
#define BK_MESH_SHADER_FRAGMENT_BODIES \
BK_FN bk_float4 bk_mesh_shade_straight(bk_float3 world, bk_float3 normal, bk_float4 vertexColor BK_MESH_U_PARAM) \
{ \
    bk_float3 n = normal; \
    if (u.hasNormals == 0 || length(n) < 1e-6f) { \
        n = cross(bk_dfdx(world), bk_dfdy(world)); \
    } \
    float len = length(n); \
    bk_float3 toViewer = (u.projection == BKProjPerspective) ? normalize(u.cameraPosition.xyz - world) \
                                                             : -u.cameraForward.xyz; \
    float ndl = len > 1e-12f ? abs(dot(n / len, toViewer)) : 1.0f; \
    bk_float3 base = vertexColor.rgb * u.color.rgb; \
    bk_float3 rgb = (u.lit != 0) ? base * (u.ambient + u.diffuse * ndl) + u.specular * pow(ndl, u.specularPower) : base; \
    float alpha = clamp(u.color.a * vertexColor.a, 0.0f, 1.0f); \
    return bk_float4(clamp(rgb, 0.0f, 1.0f), alpha); \
} \
BK_FN bk_float4 bk_mesh_shade(bk_float3 world, bk_float3 normal, bk_float4 vertexColor BK_MESH_U_PARAM) \
{ \
    bk_float4 c = bk_mesh_shade_straight(world, normal, vertexColor BK_MESH_U_ARG); \
    return bk_float4(c.rgb * c.a, c.a); \
} \
BK_FN float bk_mesh_ray_distance(bk_float3 world BK_MESH_U_PARAM) \
{ \
    bk_float3 rel = world - u.cameraPosition.xyz; \
    return (u.projection == BKProjPerspective) ? length(rel) : dot(rel, u.cameraForward.xyz); \
}

#endif
