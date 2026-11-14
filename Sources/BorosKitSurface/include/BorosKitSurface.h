// Copyright (c) 2026 Serdal Kocak. All rights reserved.
//
// BorosKitSurface: builds bone / soft-tissue surface meshes from a scan on the GPU
// (replaces the old single-threaded VTK contour + decimate + smooth + normals chain).
//  - BKSurfaceExtractor: the Metal extractor (what the app calls);
//  - BKSurfaceCore: the backend-neutral plain-C core (plan, generated marching-cubes
//    table, prefix sums, CPU reference), shared with a future Vulkan backend.

#import "BKSurfaceExtractor.h"
#import "BKSurfaceCore.h"
