// BorosKitGPUVulkan: 2D overlay engine, fragment - thin entry point (bk_overlay_shade shared with Metal).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
#version 450
#extension GL_GOOGLE_include_directive : require
#define BKO_SAMPLE(t, s, uv) texture(sampler2D(t, s), uv)
#include "bk_overlay_common.glsl"
layout(set = 0, binding = 16) uniform texture2D image;
layout(set = 0, binding = 40) uniform sampler smp;
layout(location = 0) in vec2 vUV;
layout(location = 1) in vec4 vColor;
layout(location = 0) out vec4 outColor;
BK_OVERLAY_BODIES
void main()
{
    outColor = bk_overlay_shade(vColor, vUV, image, smp);
}
