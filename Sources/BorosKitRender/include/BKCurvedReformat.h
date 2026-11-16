// BorosKitRender: BKCurvedReformat - draws curved-MPR (panorex) and cross-section pictures on the GPU
// (Metal), with the CPU reference as the fallback. Replaces Horos' CPRGenerator in Boros 6 (2026-11-15).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly. The kernel (source in BKCurvedReformat.m) is one compute thread
//   per output pixel with a std430 block of 32-bit scalars (BK_REFORMAT_PARAMS_FIELDS), a float4 frame
//   buffer, exact texel reads of the scan (texelFetch) and a float output buffer; every Metal construct
//   in it is annotated with its GLSL equivalent. The definition and the golden CPU reference are in
//   BKCurvedReformatCore.h/.c.
// - This file is the Apple glue: device, pipeline, buffers, waiting.
//
// Why (Boros 6 profile 2026-11-15): drawing a curve made the old CPU generator busy for seconds (about two
// cores, row-by-row cubic interpolation through a 3D temporary volume). On the GPU one pass writes the
// final picture directly.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "BKCurvedReformatCore.h"

@class BKVolumeTexture;

NS_ASSUME_NONNULL_BEGIN

@interface BKCurvedReformat : NSObject

// What: a generator on `device` (nil = the system default GPU); nil (and error) if the kernel cannot be built.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLDevice> device;

// What: renders the picture defined by `params` (width, height, depth, interpolation, projection,
// outOfBoundsValue, radiographK, rowCentre, slabCentre; the volume fields are filled from `volume`) and
// `frames` (params.width of them) from the scan on the GPU into `destination` (width * height floats,
// row 0 first), and waits. `capacityBytes` = memory at destination; page-aligned whole pages are
// written by the GPU directly, other memory gets one copy. Returns NO (and error) on failure.
- (BOOL)renderParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                into:(float *)destination capacity:(NSUInteger)capacityBytes error:(NSError * _Nullable * _Nullable)error;

// What: the same without waiting (page-aligned whole pages only); wait on the returned command buffer
// and check its status before reading; keep `destination` alive until then.
- (nullable id<MTLCommandBuffer>)commitParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames
                                       volume:(BKVolumeTexture *)volume into:(float *)destination
                                     capacity:(NSUInteger)capacityBytes error:(NSError * _Nullable * _Nullable)error;

// What: the CPU reference over all rows, split across the cores (rows are independent; same result for
// any number of threads). `voxels` = the scan's real values (x fastest); params' volume fields must be set.
// Why: the fallback when Metal is not used (Preferences classic switch, no GPU) and the reference for tests.
+ (void)computeOnCPUParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames
                    voxels:(const float *)voxels into:(float *)destination;

@end

NS_ASSUME_NONNULL_END
