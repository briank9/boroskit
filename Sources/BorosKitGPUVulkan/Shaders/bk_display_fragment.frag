// BorosKitGPUVulkan: 2D display, fragment - thin entry point; the maths is bk_display_shade (BKDisplayShaderBodies.h,
// shared with Metal). Original BorosKit code; no third-party code. 2026-11-26, agent "vulkan-engine".
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_display_common.glsl"
layout(std430, set = 0, binding = 0) readonly buffer BKDisplayParamsBlock { BK_DISPLAY_PARAMS_FIELDS } p;
layout(set = 0, binding = 16) uniform texture2D image;
layout(set = 0, binding = 17) uniform texture2D lut;
layout(set = 0, binding = 40) uniform sampler bkdSampler;
layout(location = 0) out vec4 outColor;
BK_DISPLAY_BODIES
void main()
{
    outColor = bk_display_shade(gl_FragCoord.xy, image, lut);
}
