// BorosKitGPU: umbrella header of the module (see BorosKitVec.h for why it exists).
// Original BorosKit code written for this project; contains no third-party code. 2026-11-26, agent "vulkan-engine".
// RULE: every new header in this folder must be listed below. Both are C++ / Objective-C++ only (guarded inside).

#include "BKGPU.h"
#include "BKGPUMetal.h"
#include "BKGPUEngineBridge.h"   // 2026-11-26: Vulkan test-engine glue (ObjC++ only, guarded)
#ifdef __OBJC__
#import "BKGPUEngine.h"          // 2026-11-26: Metal (default) / Vulkan test engine choice
#endif
