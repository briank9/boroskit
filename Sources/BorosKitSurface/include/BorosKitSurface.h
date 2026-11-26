// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: builds bone / soft-tissue surface meshes from a scan on the GPU
// (replaces the old single-threaded VTK contour + decimate + smooth + normals chain).
//  - BKSurfaceExtractor: the Metal extractor (what the app calls);
//  - BKSurfaceCore: the backend-neutral plain-C core (plan, generated marching-cubes
//    table, prefix sums, CPU reference), shared with a future Vulkan backend.

//  - BKSurfacePass (2026-11-26): the GPU flow on the shared interface (C++ only, guarded),
//    used by BKSurfaceExtractor on Metal and by the Vulkan engine.
// RULE (2026-11-26): every header in this folder is listed here (umbrella, avoids stale modules).

#import "BKSurfaceExtractor.h"
#import "BKSurfaceCore.h"
#import "BKSurfaceShaderTypes.h"
#import "BKSurfaceShaderBodies.h"   // only #defines (the shared kernel text)
#import "BKSurfacePass.h"
