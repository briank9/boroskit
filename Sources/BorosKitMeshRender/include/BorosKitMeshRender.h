// BorosKitMeshRender: umbrella header. Draws surface meshes (BorosKitMesh) with Metal,
// using the same camera as the volume renderer (BorosKitRender). macOS and iOS/iPadOS.
// No OpenGL, VTK, AppKit or UIKit in this layer.

#import "BKMeshRenderer.h"
#import "BKCropBox.h"
#import "BKMeshDrawCore.h"   // 2026-11-14: culling / texture / point rules (plain C)
