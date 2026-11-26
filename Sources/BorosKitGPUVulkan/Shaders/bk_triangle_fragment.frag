// BorosKitGPUVulkan: the milestone-1 test triangle (step M7) - fragment program: one flat colour.
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, "vulkan-engine".
#version 450

layout(std140, set = 0, binding = 1) uniform BKTriangleColour { vec4 rgba; } colour;
layout(location = 0) out vec4 outColor;

void main()
{
    outColor = colour.rgba;
}
