// BorosKitGPUVulkan: bk_point_vertex - Metal's bk_point_vertex: each point a square of 2 * lineHalfWidth pixels,
// 6 vertices (corners 0 (-,-) 1 (+,-) 2 (+,+) | 3 (-,-) 4 (+,+) 5 (-,+)); a point behind the near distance is not drawn.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;
layout(std430, set = 0, binding = 0) readonly buffer BKPointPositions { float p[]; } points;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_VERTEX_BODIES

layout(location = 0) out vec3 outWorld;

void main()
{
    uint index = uint(gl_VertexIndex) / 6u, corner = uint(gl_VertexIndex) % 6u;
    vec3 p = (u.model * vec4(points.p[3u * index], points.p[3u * index + 1u], points.p[3u * index + 2u], 1.0f)).xyz;
    outWorld = p;
    if (u.projection == BKProjPerspective && bk_view_depth(p) < u.nearDistance) {
        gl_Position = vec4(0, 0, 2, 1);
        return;
    }
    vec4 c = bk_project(p);
    vec2 halfViewport = 0.5f * vec2(max(u.viewportWidth, 1.0f), max(u.viewportHeight, 1.0f));
    float sx = (corner == 1u || corner == 2u || corner == 4u) ? 1.0f : -1.0f;
    float sy = (corner == 2u || corner == 4u || corner == 5u) ? 1.0f : -1.0f;
    c.xy += vec2(sx, sy) * u.lineHalfWidth / halfViewport * c.w;   // pixels -> clip space
    gl_Position = c;
}
