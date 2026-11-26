// BorosKitGPUVulkan: bk_mesh_fragment - the Vulkan twin of Metal's bk_mesh_fragment (colour only, no ray distance).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
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

void main()
{
    outColor = bk_mesh_shade(inWorld, inNormal, inColor);
}
