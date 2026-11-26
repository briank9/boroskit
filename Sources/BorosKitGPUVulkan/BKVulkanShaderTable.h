// BorosKitGPUVulkan: BKVulkanShaderTable - the SPIR-V programs built into the Vulkan backend.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M6).
//
// PORTING NOTES:
//   - The table is GENERATED at build time (cmake/BKEmbedSpirv.cmake): every Shaders/<name>.<stage> GLSL file
//     is compiled by glslc (--target-env=vulkan1.2: portable SPIR-V, also no maintenance4 needed; no fast-math options), checked by spirv-val, and its words
//     written into a C++ array. The tools only run on the developer machine (user decision D1); their output
//     is BorosKit's own compiled shader.
//   - A ShaderRef names a program by its file stem, which is also the Metal function name where one exists
//     (bk_mesh_vertex, bk_mesh_fragment_distance ...). Entry point is always "main".

#ifndef BK_VULKAN_SHADER_TABLE_H
#define BK_VULKAN_SHADER_TABLE_H

#include <cstddef>
#include <cstdint>

namespace boroskit {
namespace gpu {
namespace vk {

struct EmbeddedShader {
    const char *name;        // file stem, e.g. "bk_mesh_vertex"
    const uint32_t *words;   // SPIR-V
    size_t wordCount;
};

extern const EmbeddedShader kEmbeddedShaders[];
extern const size_t kEmbeddedShaderCount;

// What: the program called `name`, or nullptr.
inline const EmbeddedShader *FindShader(const char *name)
{
    if (!name) return nullptr;
    for (size_t i = 0; i < kEmbeddedShaderCount; i++) {
        const char *a = kEmbeddedShaders[i].name, *b = name;
        while (*a && *a == *b) { a++; b++; }
        if (*a == 0 && *b == 0) return &kEmbeddedShaders[i];
    }
    return nullptr;
}

}  // namespace vk
}  // namespace gpu
}  // namespace boroskit

#endif  // BK_VULKAN_SHADER_TABLE_H
