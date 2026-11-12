// BorosKitRender: BKVolumeRenderer
//
// What it is: the new GPU (Metal) volume renderer that will replace VTK + OpenGL.
// One ray is shot through the CT volume for every output pixel; what happens along the
// ray depends on the mode:
//   - Composite: classic 3D rendering (colours + opacities from a BKTransferFunction,
//     front-to-back blending, simple lighting from the surface gradient).
//   - MIP / MinIP / Average: the brightest / darkest / mean value along the ray.
// A "slab" limits rays to a slice of given thickness around a plane. With an
// orthographic camera looking straight through the slab this produces exactly the
// thick-slab (or thin, single-plane) MPR images that Horos currently gets from hidden
// VTK renderers — which is why the MPR views and the CPR slab can move to this next.
//
// Everything is offscreen: you set the camera and options, call -renderWithWidth:...,
// and get back pixels. No window, no AppKit/UIKit — works the same on Mac and iPad and
// can be tested automatically.
//
// Coordinates: all positions/directions are in patient (DICOM) millimetres, the same
// space the CPR engine uses (N3Vector).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "N3Geometry.h"
#import "BKClipPlanes.h"

@class CPRVolumeData, BKTransferFunction, BKVolumeTexture;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, BKRenderMode) {
    BKRenderModeComposite = 0,   // 3D volume rendering
    BKRenderModeMIP       = 1,   // maximum intensity projection
    BKRenderModeMinIP     = 2,   // minimum intensity projection
    BKRenderModeAverage   = 3,   // mean value along the ray (radiograph-like)
};

typedef NS_ENUM(int32_t, BKProjection) {
    BKProjectionOrthographic = 0, // parallel rays (MPR, slabs, measurements)
    BKProjectionPerspective  = 1, // rays from an eye point (3D viewing)
};

// The result of one render. Rows are stored top row first.
@interface BKRenderResult : NSObject

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;

// 8-bit RGBA, width*height*4 bytes. Projection modes: grayscale after window/level.
// Composite: colour blended over black, alpha = accumulated opacity.
@property (nonatomic, readonly) NSData *rgba8Data;

// One 32-bit float per pixel, full precision (for diagnostic export):
// projection modes = the projected CT value (outOfBoundsValue where the ray missed);
// composite = accumulated opacity 0..1.
@property (nonatomic, readonly) NSData *floatData;

// Convenience readers for single pixels (x from the left, y from the top).
- (float)valueAtX:(NSUInteger)x y:(NSUInteger)y;
- (void)getRGBA8:(uint8_t[_Nonnull 4])rgba atX:(NSUInteger)x y:(NSUInteger)y;

// Builds a CGImage from rgba8Data (caller releases). Works on macOS and iOS.
- (nullable CGImageRef)newCGImage CF_RETURNS_RETAINED;

@end

@interface BKVolumeRenderer : NSObject

// Creates a renderer on `device` (pass nil for the system default GPU). Compiles the
// shaders; returns nil + error if no GPU is available or compilation fails.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device
                                  error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLDevice> device;

// Uploads a volume to the GPU (see BKVolumeTexture). Resets the cropping box to the
// whole volume. Returns NO + error on failure.
- (BOOL)setVolumeData:(CPRVolumeData *)volumeData error:(NSError * _Nullable * _Nullable)error;

// Or reuse an already uploaded volume (e.g. several views sharing one GPU copy).
@property (nonatomic, strong, nullable) BKVolumeTexture *volumeTexture;

@property (nonatomic) BKRenderMode mode;
@property (nonatomic) BKProjection projection;

// --- Camera (patient mm) ---------------------------------------------------------
// Orthographic: cameraPosition is the CENTRE of the image plane; rays run through
//   the whole volume in both directions, so the position along the view direction
//   does not matter. viewWidth/viewHeight are the image size in mm.
// Perspective: cameraPosition is the eye; fieldOfView is the vertical angle in
//   degrees (horizontal follows the output aspect ratio).
@property (nonatomic) N3Vector cameraPosition;
@property (nonatomic) N3Vector cameraDirection;   // need not be unit length
@property (nonatomic) N3Vector cameraUp;          // made perpendicular to direction internally
@property (nonatomic) CGFloat viewWidth;          // mm (orthographic)
@property (nonatomic) CGFloat viewHeight;         // mm (orthographic)
@property (nonatomic) CGFloat fieldOfView;        // degrees (perspective), default 30

// Sample spacing along each ray in mm; 0 (default) = half the smallest voxel size.
@property (nonatomic) CGFloat sampleSpacing;

// --- Slab ------------------------------------------------------------------------
// When enabled, rays only see the part of the volume within slabThickness/2 of
// slabPlane. Thickness 0 = exactly one sample on the plane (a classic MPR slice).
@property (nonatomic) BOOL slabEnabled;
@property (nonatomic) N3Plane slabPlane;          // point + normal, patient mm
@property (nonatomic) CGFloat slabThickness;      // mm

// --- Cropping box (voxel index coordinates, inclusive) ---------------------------
// Like VTK's cropping region. Defaults to the whole volume after setVolumeData:.
@property (nonatomic) N3Vector cropMin;
@property (nonatomic) N3Vector cropMax;

// --- Clipping plane ("scissors") ---------------------------------------------------
// When enabled, everything on the side of clipPlane that its normal points to is cut
// away (patient mm). Why: the VR window's scissors / clipping tools remove part of
// the volume to look inside; one plane is the building block for those.
@property (nonatomic) BOOL clipPlaneEnabled;
@property (nonatomic) N3Plane clipPlane;

// --- Extra clipping planes (e.g. a rotated cropping box) --------------------------
// Up to BK_MAX_CLIP_PLANES (6) planes, patient mm, same rule as clipPlane: the side each
// normal points to is cut away (a point is kept only if it is inside all of them).
// They add to the crop box and the clip plane above. count 0 (or planes NULL) = none.
// Why: the VR window's cropping box can be rotated; 6 planes describe it exactly.
// BKClipPlanesFromVTK (BorosKitCore) converts VTK planes into this form.
- (void)setClipPlanes:(const N3Plane *)planes count:(NSUInteger)count;
@property (nonatomic, readonly) NSUInteger clipPlaneCount;
- (N3Plane)clipPlaneAtIndex:(NSUInteger)index;

// --- Appearance ------------------------------------------------------------------
// Grayscale window for MIP / MinIP / Average output (rgba8Data). floatData is never
// windowed. Defaults: centre 40, width 400 (soft-tissue CT).
@property (nonatomic) float windowCenter;
@property (nonatomic) float windowWidth;

// Value written to floatData where a ray misses the volume (projection modes only).
// NAN (the default) = use the volume's outOfBoundsValue (-1000 HU for CPR volumes).
// Why: the MPR views compare against VTK, which reports the volume's minimum value
// (e.g. -1024) outside the scan; setting this keeps the "outside" pixels identical.
@property (nonatomic) float missValue;

// Composite mode only. Defaults to a gray ramp over the volume's value range.
@property (nonatomic, strong, nullable) BKTransferFunction *transferFunction;

// Distance (mm) over which a transfer-function opacity value applies. Opacity is
// re-scaled to the actual sample spacing, so the image does not get darker or lighter
// when the quality / step size changes (Horos did this with its super-sampling factor).
@property (nonatomic) float opacityUnitDistance;  // default 1 mm

// Composite-mode lighting (a light at the viewer). Defaults: on, 0.2 / 0.8 / 0.2 / 10.
@property (nonatomic) BOOL shadingEnabled;
@property (nonatomic) float ambient;
@property (nonatomic) float diffuse;
@property (nonatomic) float specular;
@property (nonatomic) float specularPower;

// --- Speed ----------------------------------------------------------------------------
// Empty-space skipping (default YES). Rays jump over small blocks of the volume that
// cannot change the picture: in 3D mode, blocks whose values are all fully
// transparent under the current colour/opacity rule (e.g. the air around the head
// with a bone preset); in MIP / MinIP, blocks that cannot beat the brightest / darkest
// value already found on that ray. Samples after a jump land exactly where they would
// have anyway, so the picture is the same (checked by the image-equality tests); it
// only takes less time. The average mode never skips. Set NO to switch it off, e.g.
// from an app preference, to compare or to rule it out when chasing a problem.
// The first render of a new volume spends a few milliseconds measuring the blocks.
@property (nonatomic) BOOL skipsEmptySpace;

// Renders one image of width x height pixels and waits for the GPU to finish.
// Returns nil + error if no volume is set or the GPU work fails.
- (nullable BKRenderResult *)renderWithWidth:(NSUInteger)width
                                      height:(NSUInteger)height
                                       error:(NSError * _Nullable * _Nullable)error;

// --- GPU-only output (on-screen views) ----------------------------------------------
// The command queue this renderer submits to. On-screen views create their command
// buffers here so the 3D image and its presentation are ordered on one queue.
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

// Encodes a render of the current settings into `texture` (its full size; it needs
// MTLTextureUsageShaderWrite, e.g. a CAMetalLayer drawable with framebufferOnly = NO)
// and returns WITHOUT waiting for the GPU. The colour is laid over the opaque
// `backgroundColor` (RGBA 0..1, alpha ignored). Why: the 3D view must never block the
// main thread or copy pixels back to the CPU; the caller commits the command buffer
// (and presents the drawable) itself. Returns NO + error if no volume is set.
- (BOOL)encodeRenderToTexture:(id<MTLTexture>)texture
                commandBuffer:(id<MTLCommandBuffer>)commandBuffer
              backgroundColor:(simd_float4)backgroundColor
                        error:(NSError * _Nullable * _Nullable)error;

// Encodes a linear-filtered resize of `source` into `target` (target needs
// MTLTextureUsageShaderWrite). Why: during interaction the 3D image is rendered at a
// lower resolution and stretched to the view, like Horos' LOD.
- (void)encodeUpscaleFromTexture:(id<MTLTexture>)source
                       toTexture:(id<MTLTexture>)target
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

// For tests: size in bytes of the parameter block as the GPU compiler sees it, so
// the CPU/GPU layouts can be checked to match.
- (NSUInteger)gpuParameterBlockSize;
+ (NSUInteger)cpuParameterBlockSize;

@end

NS_ASSUME_NONNULL_END
