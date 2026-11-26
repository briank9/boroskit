// BorosKitGPUVulkan: 2D display, vertex (one full-screen triangle; BK_DISPLAY_TRIANGLE shared with Metal).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
#version 450
#extension GL_GOOGLE_include_directive : require
#include "bk_display_common.glsl"
void main()
{
    int vid = gl_VertexIndex;
    vec2 q = BK_DISPLAY_TRIANGLE(vid);
    gl_Position = vec4(q, 0.0, 1.0);
}
