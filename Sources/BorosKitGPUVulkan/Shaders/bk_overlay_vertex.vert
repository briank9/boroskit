// BorosKitGPUVulkan: 2D overlay engine, vertex - thin entry point (bk_overlay_clip shared with Metal).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
#version 450
#extension GL_GOOGLE_include_directive : require
// (the shared fragment helper is compiled here too, unused: vertex shaders have no implicit-LOD sampling)
#define BKO_SAMPLE(t, s, uv) textureLod(sampler2D(t, s), uv, 0.0)
#include "bk_overlay_common.glsl"
struct BKOverlayVertexIn { vec2 position; vec2 uv; vec4 color; };   // = BKOverlayVertex (32 bytes)
layout(std430, set = 0, binding = 0) readonly buffer BKOverlayVertices { BKOverlayVertexIn vertices[]; };
layout(location = 0) out vec2 vUV;
layout(location = 1) out vec4 vColor;
BK_OVERLAY_BODIES
void main()
{
    BKOverlayVertexIn v = vertices[gl_VertexIndex];
    gl_Position = bk_overlay_clip(v.position);
    vUV = v.uv;
    vColor = v.color;
}
