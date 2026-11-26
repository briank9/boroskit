// BorosKitGPUVulkan: bk_mesh_vertex_textured - Metal's bk_mesh_vertex_textured: bk_mesh_vertex plus texture coordinates
// (storage buffer slot 2: packed float x2 per vertex, read as a std430 float array).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;
layout(std430, set = 0, binding = 0) readonly buffer BKMeshVertices { float v[]; } vertices;
layout(std430, set = 0, binding = 2) readonly buffer BKMeshTextureCoordinates { float st[]; } tcoords;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_VERTEX_BODIES

layout(location = 0) out vec3 outWorld;
layout(location = 1) out vec3 outNormal;
layout(location = 2) out vec4 outColor;
layout(location = 3) out vec2 outTcoord;
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
    uint t = uint(gl_VertexIndex) * 2u;
    outTcoord = vec2(tcoords.st[t], tcoords.st[t + 1u]);
}
