// BorosKitGPUVulkan: bk_mesh_fragment_distance - the Vulkan twin of Metal's bk_mesh_fragment_distance.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, "vulkan-engine".
// Target 0: premultiplied lit colour (RGBA8); target 1: ray distance in mm (R32F). Maths: BKMeshShaderBodies.h.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_FRAGMENT_BODIES

layout(location = 0) in vec3 inWorld;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 0) out vec4 outColor;
layout(location = 1) out float outDistance;

void main()
{
    outColor = bk_mesh_shade(inWorld, inNormal, inColor);
    outDistance = bk_mesh_ray_distance(inWorld);
}
