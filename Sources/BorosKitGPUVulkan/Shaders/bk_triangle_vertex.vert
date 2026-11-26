// BorosKitGPUVulkan: the milestone-1 test triangle (step M7) - vertex program.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, "vulkan-engine".
// Three corners in clip space (+y up, Metal's convention; the backend flips the viewport), read from a
// storage buffer by vertex index (no vertex-input layouts, BKGPU.h).
#version 450

layout(std430, set = 0, binding = 0) readonly buffer BKTriangleCorners { float xy[]; } corners;

void main()
{
    uint i = uint(gl_VertexIndex) * 2u;
    gl_Position = vec4(corners.xy[i], corners.xy[i + 1u], 0.5, 1.0);
}
