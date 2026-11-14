// BorosKitMeshRender: BKOrientationCube - the 3D windows' orientation cube as a native BorosKit
// object (Metal drawing; geometry and camera in plain C).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - All geometry (cube, hand-drawn letters, letter outlines), the corner camera and the corner
//   rectangle come from the plain-C core BKOrientationCubeCore.h. This class only turns those
//   arrays into BKMeshObject / BKLineObject and draws them with a BKMeshRenderer into a corner
//   of a picture. A Vulkan backend reuses the core unchanged and draws the same triangle / line
//   lists with its own mesh pipeline.
// - Apple glue: simd colours, Metal textures; the camera goes in as BKCameraFrame (BKVec.h
//   vectors, plain C). No AppKit / UIKit / VTK.
//
// Plain language: the little white cube with coloured letters (L/R blue, P/A green, S/I red,
// grey letter edges) that sits in the top-right corner of the 3D window and turns with the
// patient. It replaces VTK's vtkAnnotatedCubeActor + orientation widget, which needed VTK's
// camera and a VTK render on every frame.
//
// Use: make one per window (it owns a small BKMeshRenderer on the window's GPU), then for every
// frame call -encodeToTexture:... with the main view's camera (only its rotation is used) and
// the corner rectangle in pixels (BKOrientationCubeCornerRect). For a capture (Copy / export),
// -renderWithWidth:... draws the same cube into an offscreen picture.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "BKOrientationCubeCore.h"

@class BKMeshRenderer, BKMeshObject, BKLineObject, BKRenderResult, BKVolumeCamera;

NS_ASSUME_NONNULL_BEGIN

@interface BKOrientationCube : NSObject

// What: the classic cube (labels L R P A S I, classic colours) drawn on `device` (nil = the
// card chosen by BKMetalDevice). nil + error when Metal cannot start.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device error:(NSError * _Nullable * _Nullable)error;

// The renderer it draws with (its device, command queue).
@property (nonatomic, readonly) BKMeshRenderer *renderer;

// --- Look -------------------------------------------------------------------------------
// The six face letters in BKCubeFace order (+x, -x, +y, -y, +z, -z). nil or a wrong count
// restores the classic L R P A S I. Characters BorosKit has no drawing for are left out and
// counted in skippedCharacterCount (log it: the face is then shown without that letter).
- (void)setLabels:(nullable NSArray<NSString *> *)labels;
@property (nonatomic, readonly, copy) NSArray<NSString *> *labels;
@property (nonatomic, readonly) NSUInteger skippedCharacterCount;

// Letter colour of one face (default: classic colours), the cube colour (white) and the letter
// outline colour (grey 0.5). Outlines on/off (default YES) and their width in pixels of the
// picture being drawn (default 1, like the classic 1-pixel edges).
- (void)setLetterColor:(simd_float3)color forFace:(NSInteger)face;
- (simd_float3)letterColorForFace:(NSInteger)face;
@property (nonatomic) simd_float3 cubeColor;
@property (nonatomic) simd_float3 outlineColor;
@property (nonatomic) BOOL showsOutlines;
@property (nonatomic) CGFloat outlineWidth;

// The drawable objects (cube, 6 letters, outlines), e.g. for an exporter or a test.
@property (nonatomic, readonly) NSArray<BKMeshObject *> *meshObjects;
@property (nonatomic, readonly) NSArray<BKLineObject *> *lineObjects;

// --- Camera -----------------------------------------------------------------------------
// What: the BorosKit plain-C camera frame of an interactive camera (patient mm; position = eye
// or image-plane centre, unit direction and up). Convenience for callers holding a
// BKVolumeCamera (the Metal 3D view's camera).
+ (BKCameraFrame)cameraFrameForVolumeCamera:(BKVolumeCamera *)camera;

// What: points the cube's own corner camera along `mainCamera` (rotation only; see
// BKOrientationCubeCamera) for a corner of the given aspect (width / height). NO if the main
// camera's direction / up are unusable (the previous camera is kept).
- (BOOL)setMainCamera:(BKCameraFrame)mainCamera cornerAspect:(double)cornerAspect;

// --- Drawing ----------------------------------------------------------------------------
// What: draws the cube into `viewport` (pixels of `target`, origin top-left; CGRectZero = the
// whole texture) of `target`, seen from `mainCamera`'s direction. clear = YES fills the WHOLE
// texture with clearColor first (premultiplied RGBA; e.g. transparent for a corner layer);
// NO draws over what is there. The caller commits the command buffer.
- (BOOL)encodeToTexture:(id<MTLTexture>)target
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer
               viewport:(CGRect)viewport
             mainCamera:(BKCameraFrame)mainCamera
                  clear:(BOOL)clear
             clearColor:(simd_float4)clearColor
                  error:(NSError * _Nullable * _Nullable)error;

// What: an offscreen picture width x height (transparent background, colours premultiplied)
// with the cube drawn into `viewport` (pixels, origin top-left). For captures and tests.
- (nullable BKRenderResult *)renderWithWidth:(NSUInteger)width
                                      height:(NSUInteger)height
                                    viewport:(CGRect)viewport
                                  mainCamera:(BKCameraFrame)mainCamera
                                       error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
