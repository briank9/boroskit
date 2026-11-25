// BorosKitDICOM: BKDicomVolume - builds one 3D volume (float voxels + patient geometry) from the files of a
// series, ready for BKVolumeTexture -initWithFloatVoxels:...patientToVoxel:.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Apple glue: file opening (BKDicomFile) and running the per-slice decoding on all cores with Grand Central
//   Dispatch (each slice writes only its own part of the volume, so the result is the same for any number
//   of threads). The sorting and geometry are BKDicomSeriesCore (plain C); a Windows/Linux build keeps those
//   and swaps GCD for BorosKit's parallel-for helper.
// - The matrices are COLUMN-MAJOR 4x4 doubles (column-vector convention), exactly what
//   BKVolumeTexture's -initWithFloatVoxels:...patientToVoxel: expects.
//
// Plain language: give it the files of one series (any order, single- or multi-frame); it sorts the
// slices, checks they fit together, decodes every slice into one block of numbers (x fastest, then y, then
// slice) and records where that block sits in the patient. If the block would be too large for the
// device it keeps every second pixel in each slice (and says so in `warnings`).

#import <Foundation/Foundation.h>
#import "BKDicomFile.h"

NS_ASSUME_NONNULL_BEGIN

@interface BKDicomVolume : NSObject

// What: builds the volume. `maximumVoxels` (0 = no limit): above it, slices are reduced 2x2 (or more) by
// averaging. `progress` (may be nil) is called from worker threads with 0..1 and returns NO to cancel.
// nil + error when nothing decodable is found or any slice fails to decode (never a partial picture).
+ (nullable instancetype)volumeWithFileURLs:(NSArray<NSURL *> *)urls
                              maximumVoxels:(NSUInteger)maximumVoxels
                                   progress:(nullable BOOL (^)(double fraction))progress
                                      error:(NSError * _Nullable * _Nullable)error;

// Same, from files already opened.
+ (nullable instancetype)volumeWithFiles:(NSArray<BKDicomFile *> *)files
                           maximumVoxels:(NSUInteger)maximumVoxels
                                progress:(nullable BOOL (^)(double fraction))progress
                                   error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) NSUInteger width, height, depth;
// width * height * depth floats, x fastest. Released by -releaseVoxels (e.g. once on the GPU).
@property (nonatomic, readonly, nullable) NSData *voxels;
- (void)releaseVoxels;

// Voxel size in mm (x = along rows, y = down columns, z = between slices).
@property (nonatomic, readonly) double spacingX, spacingY, spacingZ;
// What: 16 doubles, column-major: voxel (i, j, k, 1) -> patient mm, and its inverse.
- (void)getVoxelToPatient:(double *)matrix;
- (void)getPatientToVoxel:(double *)matrix;

@property (nonatomic, readonly) float minimumValue, maximumValue;
// A sensible first window: the file's own, else from the modality (CT: 400 / 2000) or the value range.
@property (nonatomic, readonly) double defaultWindowCenter, defaultWindowWidth;
@property (nonatomic, readonly) BOOL monochrome1;
@property (nonatomic, readonly) NSUInteger downsampleFactor;   // 1 = full resolution
@property (nonatomic, readonly) BKDicomFile *referenceFile;    // the first sorted slice's file (patient, study...)
@property (nonatomic, readonly) NSArray<NSString *> *warnings; // plain-language notes for the user
@property (nonatomic, readonly) NSString *transferSyntaxName;

@end

NS_ASSUME_NONNULL_END
