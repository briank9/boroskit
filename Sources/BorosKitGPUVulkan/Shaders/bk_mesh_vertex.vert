// BorosKitGPUVulkan: bk_mesh_vertex - the Vulkan twin of Metal's bk_mesh_vertex (BKMeshShaderSource.mm).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, "vulkan-engine".
//
// Entry point only: the maths (bk_project) is the shared text of BKMeshShaderBodies.h. Bindings as on Metal:
// buffer slot 0 = vertices (BKMeshGPUVertex: 10 floats each, read from a std430 float array, never vec3[]),
// slot 1 = BKMeshUniforms (std140 = the C layout, 272 bytes).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;
layout(std430, set = 0, binding = 0) readonly buffer BKMeshVertices { float v[]; } vertices;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_VERTEX_BODIES

layout(location = 0) out vec3 outWorld;    // patient mm
layout(location = 1) out vec3 outNormal;   // patient space, not normalised
layout(location = 2) out vec4 outColor;

// The see-through two-pass drawing needs bit-identical depths in both passes (Metal: [[invariant]]).
invariant gl_Position;

void main()
{
    uint b = uint(gl_VertexIndex) * 10u;
    vec3 position = vec3(vertices.v[b], vertices.v[b + 1u], vertices.v[b + 2u]);
    vec3 normal = vec3(vertices.v[b + 3u], vertices.v[b + 4u], vertices.v[b + 5u]);
    vec4 colour = vec4(vertices.v[b + 6u], vertices.v[b + 7u], vertices.v[b + 8u], vertices.v[b + 9u]);
    vec3 world = (u.model * vec4(position, 1.0f)).xyz;
    gl_Position = bk_project(world);
    outWorld = world;
    outNormal = (u.normalMatrix * vec4(normal, 0.0f)).xyz;
    outColor = u.useVertexColors != 0 ? colour : vec4(1.0f);
}
