// BorosKitRender: BKVolumeTexture
//
// What it is: a copy of a CT volume living on the graphics chip (a Metal 3D texture),
// so the GPU can sample it millions of times per frame.
//
// Storage choice — 16-bit unsigned normalised (MTLPixelFormatR16Unorm), with a
// scale + offset to get real values back:
//  * Half the memory of 32-bit float. A 800^3 CBCT is ~1 GB as 16-bit vs ~2 GB as
//    float; that difference decides whether it fits on an iPad.
//  * Hardware trilinear filtering works for R16Unorm on every Metal GPU, Mac and iPad.
//    Filtering 32-bit float textures is an optional GPU feature, not guaranteed.
//  * The volume's value range is spread over all 65,536 steps (about 0.03 HU per
//    step for a typical CT). Each voxel is stored within half a step of its true
//    value, so whole-number data (CT, CBCT, most MR) rounds back EXACTLY, and
//    interpolated samples between voxels keep ~0.03 HU resolution (the GPU rounds
//    filtered results to the texture's precision, so finer steps matter).
//    Half-float (R16Float) cannot do this — above 2048 it can only store every 2nd
//    value, above 4096 every 4th, which would alter bright bone/metal in MIP exports.
//  * Non-integer data (e.g. PET SUV) is quantised to 1/65,535 of its range — far
//    below display precision.
//
// Geometry: keeps the volume's patient(mm)->voxel transform from CPRVolumeData, so
// every render is defined in real patient millimetres, like the CPR engine.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "N3Geometry.h"

@class CPRVolumeData;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BKRenderErrorDomain;

@interface BKVolumeTexture : NSObject

// Uploads `volumeData` to `device`. Reads the voxels once on the CPU (min/max and
// whether they are all whole numbers), converts them slice-chunk by slice-chunk to
// 16-bit and copies them into a GPU-private 3D texture. Returns nil and an error if
// the volume is invalid, too large for the GPU (max 2048 voxels per side) or memory
// cannot be allocated.
- (nullable instancetype)initWithVolumeData:(CPRVolumeData *)volumeData
                                     device:(id<MTLDevice>)device
                                      error:(NSError * _Nullable * _Nullable)error;

// Same upload, from plain data instead of CPRVolumeData (added 2026-11-13).
// voxels: width*height*depth floats, x fastest, then y, then z (copied; the caller keeps
// ownership). patientToVoxel: 16 doubles, COLUMN-MAJOR, column-vector convention
// (voxel = M * (x, y, z, 1) for a patient point in mm; translation in elements 12-14);
// it becomes volumeTransform. minPixelSpacing: smallest voxel size in mm (> 0).
// outOfBoundsValue: value reported where a ray leaves the volume (e.g. -1000 HU).
// Why: new BorosKit code (the golden-output tests, a future Vulkan backend, the iPad app)
// must be able to upload a volume without the Horos-derived, LGPL CPRVolumeData class.
- (nullable instancetype)initWithFloatVoxels:(const float *)voxels
                                       width:(NSUInteger)width
                                      height:(NSUInteger)height
                                       depth:(NSUInteger)depth
                              patientToVoxel:(const double[_Nonnull 16])patientToVoxel
                             minPixelSpacing:(double)minPixelSpacing
                            outOfBoundsValue:(float)outOfBoundsValue
                                      device:(id<MTLDevice>)device
                                       error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLTexture> texture;

@property (nonatomic, readonly) NSUInteger pixelsWide;
@property (nonatomic, readonly) NSUInteger pixelsHigh;
@property (nonatomic, readonly) NSUInteger pixelsDeep;

// Patient (DICOM mm) space -> voxel index space; same meaning as
// CPRVolumeData.volumeTransform (voxel centres at whole-number coordinates).
@property (nonatomic, readonly) N3AffineTransform volumeTransform;

// Smallest voxel size in mm along any axis (used for the default sample spacing).
@property (nonatomic, readonly) CGFloat minPixelSpacing;

// Real value = storedTexel(0..1) * valueScale + valueOffset.
@property (nonatomic, readonly) float valueScale;
@property (nonatomic, readonly) float valueOffset;

// Lowest / highest voxel value found in the volume.
@property (nonatomic, readonly) float minimumValue;
@property (nonatomic, readonly) float maximumValue;

// YES when rounding a stored voxel gives back its exact original value
// (all voxels whole numbers and range <= 65535, as for CT).
@property (nonatomic, readonly, getter=isLossless) BOOL lossless;

// Value reported where a ray leaves the volume (CPRVolumeData.outOfBoundsValue, -1000 HU for CT).
@property (nonatomic, readonly) float outOfBoundsValue;

@end

NS_ASSUME_NONNULL_END
