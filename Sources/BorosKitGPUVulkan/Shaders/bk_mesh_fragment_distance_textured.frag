// BorosKitGPUVulkan: bk_mesh_fragment_distance_textured - Metal's twin: lit straight colour clamped, times the texel,
// premultiplied (BKMeshTextureModulate), plus the ray distance in target 1.
// Texture: sampled image binding 16 (slot 0) + sampler binding 40 (slot 0), BKGPU.h numbering.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine" (phase 2/3).
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_prelude.glsl"
#include "BKMeshUniformFields.h"

layout(std140, set = 0, binding = 1) uniform BKMeshUniformBlock { BK_MESH_UNIFORM_FIELDS } u;
layout(set = 0, binding = 16) uniform texture2D meshTexture;
layout(set = 0, binding = 40) uniform sampler meshSampler;

#include "BKMeshShaderBodies.h"
BK_MESH_SHADER_FRAGMENT_BODIES

layout(location = 0) in vec3 inWorld;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inTcoord;
layout(location = 0) out vec4 outColor;
layout(location = 1) out float outDistance;

void main()
{
    vec4 c = clamp(bk_mesh_shade_straight(inWorld, inNormal, inColor), 0.0f, 1.0f) * texture(sampler2D(meshTexture, meshSampler), inTcoord);
    outColor = vec4(c.rgb * c.a, c.a);
    outDistance = bk_mesh_ray_distance(inWorld);
}
