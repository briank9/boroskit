// BorosKitVec: umbrella header of the module (all public headers of this target).
//
// Original BorosKit code written for this project; contains no third-party code.
// Added 2026-11-26 by agent "vulkan-engine". Why: without an umbrella header SwiftPM / Xcode build this module from
// the whole include folder, and an incremental build did NOT notice a newly added header (stale precompiled module
// "BorosKitVec" -> "expected parameter declarator" errors in the bench build). With this file a new header is added
// HERE, which changes this file and makes every build rebuild the module.
// RULE: every new header in this folder must be listed below.

#include "BKVec.h"
#include "BKGPUTypes.h"
#include "BKOnce.h"
#include "BKParallel.h"   // C++ only (guarded inside)
