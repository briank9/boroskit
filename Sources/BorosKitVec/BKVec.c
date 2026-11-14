// BorosKitVec: BorosKit's neutral vector types (see include/BKVec.h).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// What: this target is header-only (static inline functions); this file exists because a Swift
// package target needs at least one source file.
// Why a target of its own: plain-C cores in several targets (camera maths, crop box, mesh draw
// rules) include BKVec.h. Putting it in BorosKitCore made C files import that whole module, which
// also holds Objective-C headers. A pure-C target is importable from C, Objective-C, C++ and Metal
// glue alike - and is the portable base layer the Vulkan engine will build on.
#include "BKVec.h"
