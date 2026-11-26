// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSegmentation: BKLabelSurface - the 3D surface of ONE class of a label map (2026-11-26, agent "segmentation").
//
// What: class value -> binary mask of its padded bounding box (BKLabelMaskFill16, plain-C core, written straight into
// the GPU upload) -> BKSurfaceExtractor at the half-way level 0.5 (between "outside" 0 and "inside" 1) with a light
// scan smoothing -> optional non-shrinking mesh smoothing -> a BKMesh in PATIENT millimetres (DICOM LPS), ready for
// BKMeshRenderer and for STL export (BKMeshIO) without any further transform.
// Why: segmentation structures are drawn in 3D straight from the label map (no ROI outlines, no morphing between
// slices): one exact source for 2D, 3D and STL.
// Numbers: the voxel -> patient placement is computed in double (BKLabelMaskBoxToPatient) and handed to the GPU once
// as float (mesh vertices are float, ~0.00003 mm at 300 mm from the origin). Deterministic for given settings.
// Threads: blocks until done - call from a background queue. One builder may be used from several threads at once
// (BKSurfaceExtractor is thread-safe); the label volume must not change meanwhile.
//
// ---- PORTING NOTES (Vulkan) ----------------------------------------------------------------------------------------
// Thin Apple glue only. A Vulkan version does the same four steps with BKSurfacePass (BorosKitSurface) and its own
// 16-bit 3D image upload; the mask maths (BKSegmentationCore) and the mesh smoothing core are shared unchanged.
// ---------------------------------------------------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "BKSegmentationCore.h"

@class BKMesh;
@class BKSurfaceExtractor;

NS_ASSUME_NONNULL_BEGIN

// Settings of one class surface. A fresh object holds the defaults.
@interface BKLabelSurfaceOptions : NSObject
// Gaussian blur of the 0 / 1 mask before the surface is built, sigma in voxels (default 0.5; 0 = the raw voxel
// staircase). Small values round the voxel steps without moving the surface noticeably.
@property (nonatomic) float maskSmoothing;
// Non-shrinking mesh smoothing rounds after the build (default 10; 0 = off), pass band 0.1.
@property (nonatomic) NSUInteger meshSmoothingIterations;
@end

@interface BKLabelSurface : NSObject

// Uses the caller's extractor (it owns the GPU programs and the command queue).
- (instancetype)initWithExtractor:(BKSurfaceExtractor *)extractor;

@property (nonatomic, readonly) BKSurfaceExtractor *extractor;

// The surface of every voxel labelled `value`. nil + error when the class has no voxels, the volume has no labels,
// or the GPU build fails (e.g. BKSurfaceErrorTooLarge). `options` nil = defaults. Blocks until done.
- (nullable BKMesh *)meshForLabelVolume:(const BKLabelVolume *)volume
                                  value:(uint16_t)value
                                options:(nullable BKLabelSurfaceOptions *)options
                                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
