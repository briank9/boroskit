// BorosKitGPUVulkan: bk_line_vertex - Metal's bk_line_vertex: each segment as a screen-aligned rectangle of
// 2 * lineHalfWidth pixels (6 vertices: corners 0,1,4 at the start, 2,3,5 at the end; 1,4,5 on the left side),
// perspective segments cut at the near distance first. Points: packed float x3 (storage slot 0).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;
layout(std430, set = 0, binding = 0) readonly buffer BKLinePoints { float p[]; } points;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_VERTEX_BODIES

layout(location = 0) out vec3 outWorld;

vec3 bk_point(uint i) { return vec3(points.p[3u * i], points.p[3u * i + 1u], points.p[3u * i + 2u]); }

void main()
{
    uint segment = uint(gl_VertexIndex) / 6u, corner = uint(gl_VertexIndex) % 6u;
    vec3 a = (u.model * vec4(bk_point(segment * 2u), 1.0f)).xyz;
    vec3 b = (u.model * vec4(bk_point(segment * 2u + 1u), 1.0f)).xyz;
    if (u.projection == BKProjPerspective) {
        float za = bk_view_depth(a), zb = bk_view_depth(b);
        float zmin = u.nearDistance;
        if (za < zmin && zb < zmin) {           // entirely behind: draw nothing
            gl_Position = vec4(0, 0, 2, 1);
            outWorld = a;
            return;
        }
        if (za < zmin) a = mix(a, b, (zmin - za) / (zb - za));
        else if (zb < zmin) b = mix(b, a, (zmin - zb) / (za - zb));
    }
    vec4 ca = bk_project(a), cb = bk_project(b);
    vec2 halfViewport = 0.5f * vec2(max(u.viewportWidth, 1.0f), max(u.viewportHeight, 1.0f));
    vec2 sa = ca.xy / ca.w * halfViewport, sb = cb.xy / cb.w * halfViewport;   // pixels
    vec2 d = sb - sa;
    d = length(d) > 1e-6f ? normalize(d) : vec2(1, 0);
    vec2 normal = vec2(-d.y, d.x);
    bool atEnd = (corner == 2u || corner == 3u || corner == 5u);
    float side = (corner == 1u || corner == 4u || corner == 5u) ? 1.0f : -1.0f;
    vec4 q = atEnd ? cb : ca;
    q.xy += normal * side * u.lineHalfWidth / halfViewport * q.w;   // pixels -> clip space
    gl_Position = q;
    outWorld = atEnd ? b : a;
}
