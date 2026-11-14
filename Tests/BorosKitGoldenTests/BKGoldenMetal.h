// BorosKitGoldenTests: BKGoldenMetal (the Metal "producer" of the golden-output harness)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: runs each test case (BKGoldenCore.h) through the real BorosKit Metal
// classes and returns the results in the plain containers of BKGoldenCore.h.
// Why separate: the cases, files and comparers are backend-neutral C; only this file
// knows about Metal. A Vulkan backend gets its own producer with the same operations.
//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
// A Vulkan producer implements the same six operations with the same inputs:
//   volume render (case -> RGBA8 + float values), 2D image layer render (case -> RGBA8),
//   surface extraction (case -> mesh), mesh render (case + mesh -> RGBA8 + float ray
//   distance), and "read back the stored 16-bit volume" (to feed the CPU reference).
// Mesh smoothing/decimation and scene export are CPU code (BorosKitMesh C++ core); the
// Vulkan build runs the same C++ core and compares against the same references.
// ---------------------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "BKGoldenCore.h"

@class BKMesh, BKVolumeTexture;

NS_ASSUME_NONNULL_BEGIN

@interface BKGoldenMetalProducer : NSObject

// Uploads `volume` once (plain-float path, no CPRVolumeData). nil + error without a GPU.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device volume:(const BKGoldenVolume *)volume
                                  error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) BKVolumeTexture *volumeTexture;

// Volume render: rgba (U8 x4) and values (F32 x1: projected HU, or accumulated opacity
// in composite mode). Caller frees both. Returns NO + error on failure.
- (BOOL)renderVolumeCase:(const BKGoldenVolumeCase *)c rgba:(BKGoldenImage *)rgba values:(BKGoldenImage *)values
                   error:(NSError * _Nullable * _Nullable)error;

// 2D display of one axial phantom slice: rgba (U8 x4).
- (BOOL)renderImageCase:(const BKGoldenImageCase *)c volume:(const BKGoldenVolume *)volume rgba:(BKGoldenImage *)rgba
                  error:(NSError * _Nullable * _Nullable)error;

// Surface extraction (mesh in patient mm, with normals).
- (nullable BKMesh *)extractSurfaceCase:(const BKGoldenSurfaceCase *)c error:(NSError * _Nullable * _Nullable)error;

// Mesh render: rgba (U8 x4) and ray distance (F32 x1, +infinity where no surface).
- (BOOL)renderMeshCase:(const BKGoldenMeshRenderCase *)c mesh:(BKMesh *)mesh rgba:(BKGoldenImage *)rgba
              distance:(BKGoldenImage *)distance error:(NSError * _Nullable * _Nullable)error;

// The volume exactly as stored on the GPU: one 16-bit step value (0...65535) per voxel,
// returned as floats (x fastest). Real value = steps / 65535 * valueScale + valueOffset.
// Why: the CPU reference extractor must see the very numbers the GPU sees.
- (nullable NSData *)storedVolumeStepsWithError:(NSError * _Nullable * _Nullable)error;

@end

// BKMesh <-> plain mesh (positions/normals copied as 3 floats per vertex).
BKGoldenMesh BKGoldenMeshFromBKMesh(BKMesh *mesh);
BKMesh *_Nullable BKMeshFromGoldenMesh(const BKGoldenMesh *mesh);

NS_ASSUME_NONNULL_END
