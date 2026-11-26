// BorosKit GPU tests: a MetalDevice prepared for the shared tests (Objective-C++ only).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
// What: the preferred Metal GPU as a BKGPU.h Device, with the mesh shader library (BKMeshShaderSource, compiled with
// BKMetalDevice's options exactly as BKMeshRenderer does) and the test triangle's two tiny MSL functions.
#ifndef BK_GPU_TEST_METAL_H
#define BK_GPU_TEST_METAL_H
#include "BKGPU.h"
#include <memory>
namespace bkshared {
std::unique_ptr<boroskit::gpu::Device> MakeTestMetalDevice();
}
#endif
