#!/bin/zsh
# BorosKit: refresh the committed SPIR-V table (Sources/BorosKitGPUVulkan/BKVulkanShaderTable.generated.cpp) from OUR GLSL.
# Original BorosKit code written for this project. 2026-11-26, agent "vulkan-engine".
#
# Why: SwiftPM / Xcode (Boros 6) cannot run glslc, so they compile a committed copy of the table that CMake generates
# (glslc + spirv-val from the installed Vulkan SDK, user decision D1). ctest "vulkan.committed_shader_table_up_to_date"
# fails until this script is run after a GLSL change. Needs VULKAN_SDK (or ~/VulkanSDK/<version>/macOS).
# Usage (repository root):  docs/tools/update-vulkan-shaders.sh [build-folder]
set -e
BUILD="${1:-build-cmake}"
if [[ -z "${VULKAN_SDK:-}" ]]; then
  VULKAN_SDK=$(ls -d $HOME/VulkanSDK/*/macOS 2>/dev/null | sort -V | tail -1)
  export VULKAN_SDK
fi
cmake -S . -B "$BUILD" > /dev/null
cmake --build "$BUILD" --target boroskit_gpu_vulkan -j 4 > /dev/null
cp "$BUILD/shaders/BKVulkanShaderTable.cpp" Sources/BorosKitGPUVulkan/BKVulkanShaderTable.generated.cpp
echo "updated Sources/BorosKitGPUVulkan/BKVulkanShaderTable.generated.cpp from $BUILD"
