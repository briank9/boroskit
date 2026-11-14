// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: BKSurfaceExtractor
//
// What it is: builds a surface mesh (BKMesh) of everything in a scan that is at or
// above a threshold, e.g. bone at 300 HU or skin at -500 HU, on the graphics chip.
//
// Why: the old Horos Surface Rendering window built these surfaces with VTK on one CPU
// core (contour + decimate + smooth + normals): about 10 s at half resolution and 28 s
// for one full-resolution CBCT surface. This class does the same job with GPU compute
// programs (a row-based "marching cubes", in the style of the "Flying Edges" method), and
// hands back a ready-to-draw BKMesh for BKMeshRenderer.
//
// What you get:
//   - one SHARED vertex per surface crossing (indexed mesh, no duplicated corners), so
//     the surface is closed (watertight) wherever the bone does not touch the edge of the
//     scan, and edgeReport shows no holes or bad edges;
//   - triangles anticlockwise seen from outside (BKMesh convention);
//   - normals from the (smoothed) scan values: they point from the bone outward, which
//     is smoother and more exact than normals averaged from the triangles;
//   - coordinates in patient mm (default) or any voxel -> output transform you give.
//
// Settings:
//   - threshold: in REAL units (HU for CT), converted with the volume's valueScale/Offset.
//   - resolution (0, 1]: like the old Horos setting (VTK resample "magnification"): the
//     grid is thinned in X and Y only, Z stays as scanned. 1 = every voxel, 0.5 = every
//     second voxel in X and Y (about 4x fewer triangles). Grid points between voxels are
//     read with linear interpolation, so no separate resampling step is needed.
//   - scanSmoothing: a gentle Gaussian blur of the scan values before the surface is
//     built (sigma in voxels of the original scan, 0 = off, max 10). Unlike smoothing the
//     finished mesh, this does not shrink the bone; it calms noise (sigma 0.5-1 is a
//     good start for CBCT).
//
// Threads: an extractor may be used from several threads at once (e.g. bone and skin
// built in parallel): every call has its own GPU buffers; the compiled programs and the
// command queue are shared and safe to share. Calls BLOCK until the mesh is ready, so
// call them from a background queue, not the main thread. Two thresholds with the same
// settings are cheaper in one call (-extractSurfacesFromVolume:thresholds:...), because
// the sampling/smoothing work is done once.
//
// Memory: about 2 bytes per grid point for the working buffer (+2 more when resolution
// < 1 or smoothing is on, +2 more during smoothing), e.g. ~380-760 MB for a 512x512x727
// CBCT at full resolution, ~95-190 MB at resolution 0.5; plus the result (32 bytes per
// vertex + 12 per triangle), which exists twice for a moment while it is copied into the
// BKMesh. All temporary GPU memory is freed before the call returns. Requests that
// would not fit (Metal's per-buffer limit or the GPU's recommended working set) fail
// with BKSurfaceErrorTooLarge instead of crashing: retry at a lower resolution.
//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
// Backend-neutral parts (reuse unchanged): BKSurfaceCore.h/.c (plan, generated MC table,
// row prefix sum, CPU reference extractor) and BKSurfaceShaderTypes.h (the std430
// parameter struct). A Vulkan backend must implement only what BKSurfaceExtractor.m does:
//   1. Upload the volume as a VK_FORMAT_R16_UNORM 3D image; create one sampler (linear,
//      clamp-to-edge, normalised coordinates). If the device cannot linearly filter
//      R16_UNORM 3D images, set sampling = BK_SURFACE_SAMPLING_MANUAL (shader does it).
//   2. Translate the 4 kernels in BKSurfaceShaderSource.mm to GLSL compute (1:1: storage
//      buffers of uint/vec4, shared memory, barriers; no subgroup ops needed).
//   3. Buffers (sizes from BKSurfacePlan): field (+ a second one for smoothing), packed,
//      2 row tables (host-visible), table (BKSurfaceFillGPUTable), outputs (host-visible).
//   4. Sequence: sample -> blur x/y/z (ping-pong, barrier between) -> [per threshold]
//      classify (workgroup per row, BK_SURFACE_ROW_THREADS threads, power of two) ->
//      wait -> BKSurfaceExclusiveScan on both row tables -> allocate outputs -> emit
//      (same workgroups) -> wait -> copy into the mesh.
//   5. Validate with the unit tests' golden numbers and BKSurfaceReferenceExtract.
// ---------------------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@class BKVolumeTexture;
@class BKMesh;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BKSurfaceErrorDomain;

typedef NS_ERROR_ENUM(BKSurfaceErrorDomain, BKSurfaceErrorCode) {
    BKSurfaceErrorInvalidInput = 1,  // bad threshold / resolution / smoothing / transform / volume
    BKSurfaceErrorTooLarge = 2,      // does not fit in GPU memory at this resolution
    BKSurfaceErrorOutOfMemory = 3,   // a buffer could not be allocated
    BKSurfaceErrorGPUFailed = 4,     // the GPU reported an error (underlying error in NSUnderlyingErrorKey)
};

// How grid points between voxels are read (only matters when resolution < 1 or
// smoothing is on; at resolution 1 the grid points ARE voxels).
typedef NS_ENUM(NSInteger, BKSurfaceSampling) {
    BKSurfaceSamplingHardwareLinear = 0,   // the GPU's texture filter (default, fastest)
    BKSurfaceSamplingManualTrilinear = 1,  // written-out interpolation: same numbers on every GPU/backend
};

// The less common settings of an extraction. A fresh object holds the defaults.
@interface BKSurfaceOptions : NSObject <NSCopying>
// (0, 1], default 1. See the header comment.
@property (nonatomic) float resolution;
// Gaussian pre-blur sigma in voxels of the original scan, default 0 (off), max 10.
@property (nonatomic) float scanSmoothing;
// Default BKSurfaceSamplingHardwareLinear.
@property (nonatomic) BKSurfaceSampling sampling;
// Optional: where vertices go, as a matrix from VOXEL INDEX space (voxel centres at
// whole numbers, as in BKVolumeTexture) to the output coordinates (column vectors:
// out = M * (i, j, k, 1)). Default (hasOutputTransform = NO): patient mm, i.e. the
// inverse of the volume's volumeTransform. Example: the Horos surface window keeps
// meshes in "VTK-local" coordinates, diag(spacingX, spacingY, +-sliceInterval).
// Normals follow with the inverse-transpose; a mirroring matrix (negative determinant,
// e.g. a negative z scale) automatically flips the triangle order so triangles stay
// anticlockwise from outside and normals stay outward.
@property (nonatomic) simd_float4x4 outputTransform;
@property (nonatomic) BOOL hasOutputTransform;
@end

// How long an extraction took and how big it was (for the app's log).
@interface BKSurfaceTimings : NSObject
@property (nonatomic, readonly) double samplingMilliseconds;    // scan -> grid copy + smoothing (0 if neither needed)
@property (nonatomic, readonly) double extractionMilliseconds;  // classify + prefix sum + emit (all thresholds)
@property (nonatomic, readonly) double meshMilliseconds;        // copying the result into BKMesh objects
@property (nonatomic, readonly) double totalMilliseconds;       // the whole call
@property (nonatomic, readonly) NSUInteger vertexCount;         // all meshes together
@property (nonatomic, readonly) NSUInteger triangleCount;
@property (nonatomic, readonly) NSUInteger gridWidth, gridHeight, gridDepth;
@property (nonatomic, readonly) NSUInteger peakTemporaryBytes;  // largest GPU working memory, result buffers included
// The same numbers as a dictionary (keys are the property names), for logging.
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *dictionaryRepresentation;
@end

@interface BKSurfaceExtractor : NSObject

// Compiles the GPU programs (once per GPU, shared by all extractors) and makes a command
// queue. Returns nil + error if there is no GPU or the programs fail to compile.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError * _Nullable * _Nullable)error;
// Same, but uses the caller's command queue (must belong to `device`).
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           commandQueue:(nullable id<MTLCommandQueue>)commandQueue
                                  error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

// The most common call: one surface in patient mm. Blocks until done.
- (nullable BKMesh *)extractSurfaceFromVolume:(BKVolumeTexture *)volume
                                    threshold:(float)threshold
                                   resolution:(float)resolution
                                scanSmoothing:(float)scanSmoothing
                                        error:(NSError * _Nullable * _Nullable)error;

// Several thresholds with the same settings (e.g. @[@300, @-500] for bone and skin);
// returns one mesh per threshold, in the same order. `options` nil = defaults. If
// `timings` is given it receives this call's numbers. Blocks until done.
- (nullable NSArray<BKMesh *> *)extractSurfacesFromVolume:(BKVolumeTexture *)volume
                                               thresholds:(NSArray<NSNumber *> *)thresholds
                                                  options:(nullable BKSurfaceOptions *)options
                                                  timings:(BKSurfaceTimings * _Nullable * _Nullable)timings
                                                    error:(NSError * _Nullable * _Nullable)error;

// The timings of the most recently FINISHED call on this extractor (any thread), as
// BKSurfaceTimings.dictionaryRepresentation; nil before the first call. With concurrent
// calls prefer the `timings:` argument, which belongs to exactly one call.
@property (atomic, readonly, copy, nullable) NSDictionary<NSString *, NSNumber *> *lastTimings;

@end

NS_ASSUME_NONNULL_END
