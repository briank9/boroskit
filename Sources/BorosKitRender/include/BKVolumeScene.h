// BorosKitRender: BKVolumeScene
//
// What it is: everything the interactive 3D view shows, without the view itself: the
// Metal renderer, the camera, the applied preset, window/level, background colour and
// the adaptive interactive quality. The Mac view (and later the iPad view) only owns a
// screen surface and forwards mouse/touch moves here; a test can drive the very same
// object offscreen.
//
// Adaptive quality (why): Horos always drops resolution while you rotate (its LOD).
// On a fast GPU that is unnecessary and makes the image swim. Here the scene measures
// how long frames take on the GPU and only steps down (75 %, then 50 % resolution,
// then a coarser sample step...) while interacting AND only if full quality would miss
// the frame budget (default 16 ms ~ 60 frames/s). It steps back up when there is room,
// and always renders full quality once the interaction ends.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "BKVolumeRenderer.h"
#import "BKVolumeCamera.h"

@class CPRVolumeData, BKPreset, BKVolumeTexture;

NS_ASSUME_NONNULL_BEGIN

// One interactive quality level: the fraction of the view's pixels rendered per axis
// and the multiplier on the sample spacing along each ray.
typedef struct {
    float resolutionScale;    // 1 = full resolution, 0.5 = half width and half height
    float sampleStepFactor;   // 1 = full quality, 2 = samples twice as far apart
} BKQualityLevel;

// Relative GPU cost of a level compared with full quality (pixels x samples per ray).
float BKQualityLevelRelativeCost(BKQualityLevel level);

// The default ladder: 100 %, 75 %, 50 % resolution, then 50 % with a double sample step,
// then 35 % with a double step. Level 0 is always full quality.
NSArray<NSValue *> *BKDefaultQualityLevels(void);

// --- Pure decision functions (unit-tested) ------------------------------------------
// Level to START an interaction with, from the time of the last full-quality frame:
// the best level whose estimated time fits the budget (0 if full quality fits, or if
// no full-quality time is known yet).
NSInteger BKInitialInteractiveQualityLevel(const BKQualityLevel *levels, NSInteger count,
                                           double lastFullQualityFrameTime, double budget);

// Level for the NEXT interactive frame, given the level and GPU time of the last one.
// Over budget -> one step coarser. Comfortably under budget (the next finer level is
// estimated to take <= 80 % of the budget) -> one step finer. Otherwise stay. One step
// at a time so quality never jumps around.
NSInteger BKNextInteractiveQualityLevel(const BKQualityLevel *levels, NSInteger count,
                                        NSInteger currentLevel, double lastFrameTime, double budget);

@interface BKVolumeScene : NSObject

// Creates the scene with its own renderer (nil device = default GPU).
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device
                                  error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) BKVolumeRenderer *renderer;
@property (nonatomic, readonly) BKVolumeCamera *camera;

// Loads a volume (or shares an uploaded one) and fits the camera to it.
- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, strong, nullable) BKVolumeTexture *volumeTexture;

// The volume's bounding box in patient mm (zero box if none).
@property (nonatomic, readonly) N3Vector volumeBoundsMin;
@property (nonatomic, readonly) N3Vector volumeBoundsMax;

// Rendering mode passthrough (3D, MIP, MinIP, mean).
@property (nonatomic) BKRenderMode mode;

// Empty-space skipping passthrough (default YES): same picture, drawn faster.
// See BKVolumeRenderer.skipsEmptySpace.
@property (nonatomic) BOOL skipsEmptySpace;

// --- Preset & window/level ------------------------------------------------------------
// Applies a preset like the VR window: colours/opacity, WL/WW, lighting, projection and
// background. Keeps the camera direction and zoom.
- (void)applyPreset:(BKPreset *)preset;
@property (nonatomic, strong, readonly, nullable) BKPreset *preset;

// Current window level / width. Composite mode: moves the preset's colour/opacity
// (simple presets) or the first curve (advanced presets), like the VR window.
// Projection modes: the grayscale window.
@property (nonatomic) float windowCenter;
@property (nonatomic) float windowWidth;

// The VR window's WL/WW drag: per event, level -= dy * WW/100 and width += dx * WW/100
// (view points, y down), width never below 0.1.
- (void)adjustWindowLevelByDeltaX:(CGFloat)dx deltaY:(CGFloat)dy;

// Background behind the volume (RGB 0..1). Set from the preset; can be changed.
@property (nonatomic) simd_float4 backgroundColor;

// --- Camera shortcuts ---------------------------------------------------------------
// Fits the camera to the volume and shows the Horos reset view (left side, head up).
- (void)resetCamera;

// --- Adaptive interactive quality ------------------------------------------------------
// Frame-time budget in seconds while interacting (default 0.016).
@property (nonatomic) double targetInteractiveFrameTime;
// The ladder of levels (BKQualityLevel in NSValue). Level 0 must be full quality.
@property (nonatomic, copy) NSArray<NSValue *> *qualityLevels;
// Sample spacing at full quality in mm (0 = automatic: half the smallest voxel).
@property (nonatomic) CGFloat baseSampleSpacing;

// Call when a drag/pinch starts and ends. Ending makes the next frame full quality.
- (void)beginInteraction;
- (void)endInteraction;
@property (nonatomic, readonly, getter=isInteracting) BOOL interacting;

// The level used for the most recent frame and the one chosen for the next (debugging).
@property (nonatomic, readonly) NSInteger currentQualityLevel;
// GPU time of the last frame and of the last full-quality frame, seconds (0 = unknown).
@property (nonatomic, readonly) double lastFrameTime;
@property (nonatomic, readonly) double lastFullQualityFrameTime;

// Records a measured frame time for a level (called automatically from the GPU
// completion handler; public so tests and wall-clock callers can feed it).
- (void)recordFrameTime:(double)seconds atQualityLevel:(NSInteger)level;

// --- Rendering ------------------------------------------------------------------------
// Encodes one frame into `target` (needs MTLTextureUsageShaderWrite) at the current
// quality level, without waiting. Measures the GPU time when the command buffer
// completes. Returns NO + error if nothing can be drawn (e.g. no volume).
- (BOOL)encodeFrameToTexture:(id<MTLTexture>)target
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                       error:(NSError * _Nullable * _Nullable)error;

// The size actually ray-cast for a target of `size` at quality `level` (tests/debug).
- (CGSize)renderSizeForTargetSize:(CGSize)size qualityLevel:(NSInteger)level;

@end

NS_ASSUME_NONNULL_END
