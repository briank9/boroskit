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

// Colour (RGB) scans (Boros 6, 2026-11-24, vr-colour-fusion): uploads a colour scan as an RGBA8 3D texture (red,
// green, blue in .rgb, 0..1 = byte / 255; .a = 1). voxels: width*height*depth voxels of bytesPerVoxel bytes each, x
// fastest; the red / green / blue bytes of a voxel at offsets redByte / greenByte / blueByte (the app's colour scans:
// 4 bytes A, R, G, B -> 1, 2, 3). patientToVoxel / minPixelSpacing as for -initWithFloatVoxels:... . The "values" of
// a colour scan are the channel bytes: valueScale 255, valueOffset 0, minimum 0, maximum 255, outside value 0.
// Why: the native 3D window draws colour scans with BorosKit (no VTK); the renderer reads the three channels.
// PORTING NOTE: RGBA8_UNORM 3D with linear filtering is core Vulkan (mandatory format feature).
- (nullable instancetype)initWithColorVoxels:(const uint8_t *)voxels
                               bytesPerVoxel:(NSUInteger)bytesPerVoxel
                                     redByte:(NSUInteger)redByte
                                   greenByte:(NSUInteger)greenByte
                                    blueByte:(NSUInteger)blueByte
                                       width:(NSUInteger)width
                                      height:(NSUInteger)height
                                       depth:(NSUInteger)depth
                              patientToVoxel:(const double[_Nonnull 16])patientToVoxel
                             minPixelSpacing:(double)minPixelSpacing
                                      device:(id<MTLDevice>)device
                                       error:(NSError * _Nullable * _Nullable)error;

// Already-quantised 16-bit data (2026-11-26, agent "segmentation"): what: the texture is filled slice-chunk by
// slice-chunk by `fill`, which writes `sliceCount` slices (x fastest, width*height per slice) of 16-bit STEPS starting
// at slice `firstSlice` into `steps`; real value = steps / 65535 * valueScale + valueOffset. minimumValue /
// maximumValue are taken as given (no scan of the data). Returns nil + error if fill returns NO.
// Why: a segmentation class becomes a 0 / 1 mask for the surface builder (steps 0 / 65535, valueScale 1): built
// straight into the GPU upload buffer (about 64 MB at a time) instead of a full-size float copy (a whole-skull mask
// box would otherwise need ~0.5 GB of floats). patientToVoxel / minPixelSpacing / outOfBoundsValue as for
// -initWithFloatVoxels:... . PORTING NOTE: a Vulkan upload fills its staging buffer through the same callback.
- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                                 depth:(NSUInteger)depth
                            valueScale:(float)valueScale
                           valueOffset:(float)valueOffset
                          minimumValue:(float)minimumValue
                          maximumValue:(float)maximumValue
                        patientToVoxel:(const double[_Nonnull 16])patientToVoxel
                       minPixelSpacing:(double)minPixelSpacing
                      outOfBoundsValue:(float)outOfBoundsValue
                                device:(id<MTLDevice>)device
                             fillSteps:(BOOL (^)(NSUInteger firstSlice, NSUInteger sliceCount, uint16_t *steps))fill
                                 error:(NSError * _Nullable * _Nullable)error;

// YES for a colour scan (see above): the texture is RGBA8 and the renderer reads its three channels.
@property (nonatomic, readonly, getter=isColor) BOOL color;

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
