// BorosKitGPUVulkan: bk_line_fragment_distance - Metal's twin (lines and points): flat colour, premultiplied, plus the ray distance.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;

layout(location = 0) in vec3 inWorld;
layout(location = 0) out vec4 outColor;
layout(location = 1) out float outDistance;

void main()
{
    float alpha = clamp(u.color.a, 0.0f, 1.0f);
    outColor = vec4(clamp(u.color.rgb, 0.0f, 1.0f) * alpha, alpha);
    vec3 rel = inWorld - u.cameraPosition.xyz;
    outDistance = (u.projection == BKProjPerspective) ? length(rel) : dot(rel, u.cameraForward.xyz);
}
