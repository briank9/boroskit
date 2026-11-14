// BorosKitMeshRender: BKCropBox - the 3D window's cropping box as a native BorosKit object.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - All the maths lives in plain C (BKBoxWidgetMath.h: the box and its moves; BKCropBoxCore.h:
//   picking, drags, clipping the drawing by the slab, saving / restoring as 6 planes). This class
//   only keeps the state and turns the C results into drawable objects. A Vulkan backend reuses
//   the C files unchanged and replaces BKLineObject / BKMeshObject by its own drawables.
// - simd types only (no N3Vector / N3Plane). Planes in and out are simd_float4 in the GPU
//   packing (nx, ny, nz, w; cut where n.x + w > 0), std430 friendly.
// - No AppKit / UIKit / VTK: the app hands in the camera (BKCameraFrame, mm), the view size in
//   points and the mouse positions; it gets back "did the box change" and the 6 clip planes.
//
// Plain language: the box the user drags around the part of the scan to keep. It knows
//   * where it is (centre, three axes - it may be turned - and half sizes, in mm);
//   * whether it is shown, and whether it crops the volume (a fresh box around the whole scan
//     crops nothing);
//   * how the mouse changes it (face handles, centre handle, faces, right/middle buttons);
//   * how it looks: white edges, green round handles, a red handle / yellow face / green edges
//     while dragged (the classic window's colours), handles the same size on screen at any zoom,
//     everything outside the thick slab (if any) cut away.
// The drawable objects are in "world" units = mm x worldScale, so they can join a scene that
// is not in mm (the Boros 3D window's overlay works in VTK's scaled world).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>
#import "BKBoxWidgetMath.h"
#import "BKCropBoxCore.h"
#import "BKCameraMath.h"

@class BKLineObject, BKMeshObject;

NS_ASSUME_NONNULL_BEGIN

@interface BKCropBox : NSObject

// What: a box at `defaultBox` (mm) that crops nothing yet, hidden.
// minimumEdge: the smallest edge length (mm) a drag may make (see BKCropBoxMinimumEdge).
- (instancetype)initWithDefaultBox:(BKOrientedBox)defaultBox minimumEdge:(double)minimumEdge;

// --- State ---------------------------------------------------------------------------------
// The box now (mm).
@property (nonatomic, readonly) BKOrientedBox box;
// Where a reset puts it (usually around the whole scan).
@property (nonatomic) BKOrientedBox defaultBox;
@property (nonatomic) double minimumEdge;
// Shown (outline + handles drawn, mouse can grab it). Hiding keeps the crop.
@property (nonatomic, getter=isVisible) BOOL visible;
// YES once the user changed the box or a cropped box was restored: then -getClipPlanes: gives
// the 6 face planes. NO for the untouched default box (nothing is cropped).
@property (nonatomic, readonly) BOOL cropsVolume;

// What: puts the box back to defaultBox; crops nothing (visibility unchanged).
- (void)resetToDefaultBox;
// What: sets the box (mm) and whether it crops (restoring a saved state).
- (void)setBox:(BKOrientedBox)box cropsVolume:(BOOL)cropsVolume;

// --- Mouse -----------------------------------------------------------------------------------
// What: mouse-down at view point (x, yDown) (origin top-left) of a view of viewWidth x viewHeight
// points seen through `camera`. button: BKCropButtonLeft / Right / Middle. cutPlanes: planes that
// hide part of the scene (the thick slab), may be NULL. Returns YES and starts a drag when the
// box (visible) is under the mouse; NO otherwise (the click is the camera's).
- (BOOL)beginDragAtViewX:(double)x yDown:(double)yDown button:(int32_t)button shift:(BOOL)shift
                  camera:(BKCameraFrame)camera viewWidth:(double)viewWidth viewHeight:(double)viewHeight
               cutPlanes:(nullable const simd_float4 *)cutPlanes count:(NSUInteger)cutPlaneCount;
// What: one mouse move during a drag (view points, y down). Returns YES when the box changed
// (it then crops the volume).
- (BOOL)continueDragByViewX:(double)dx yDown:(double)dyDown camera:(BKCameraFrame)camera viewHeight:(double)viewHeight;
// What: mouse-up: the drag and its highlights end.
- (void)endDrag;
@property (nonatomic, readonly, getter=isDragging) BOOL dragging;
// The drag in progress (mode, grabbed part, highlights); mode BKCropDragNone when none.
@property (nonatomic, readonly) BKCropBoxDrag drag;
// Short name of the drag in progress for logs ("face move", "move", "turn", "resize"), nil if none.
@property (nonatomic, readonly, nullable) NSString *dragDescription;

// --- Drawing ---------------------------------------------------------------------------------
// The objects to draw (always the same list: the outline, the 7 handles, the highlighted face).
// Their visibility and shape follow -updateDrawingWithCamera:...; all hidden while the box is.
@property (nonatomic, readonly) NSArray *drawObjects;
// Drawing units = mm x worldScale (default 1).
@property (nonatomic) double worldScale;
// Handle radius on screen, view points (default 5).
@property (nonatomic) double handleRadiusPoints;
// Edge width in output pixels (default 1).
@property (nonatomic) CGFloat lineWidth;
// Colours (RGB 0..1): edges white, edges while dragged green, handles green, grabbed handle red,
// grabbed face yellow (see-through, faceOpacity 0.25).
@property (nonatomic) simd_float3 outlineColor;
@property (nonatomic) simd_float3 selectedOutlineColor;
@property (nonatomic) simd_float3 handleColor;
@property (nonatomic) simd_float3 selectedHandleColor;
@property (nonatomic) simd_float3 selectedFaceColor;
@property (nonatomic) float faceOpacity;

// What: rebuilds the drawable objects for this camera and view height (handle size on screen),
// cut by `cutPlanes` (the thick slab; NULL / 0 = none). Cheap: call it on every frame.
- (void)updateDrawingWithCamera:(BKCameraFrame)camera viewHeight:(double)viewHeight
                      cutPlanes:(nullable const simd_float4 *)cutPlanes count:(NSUInteger)cutPlaneCount;

// --- Crop ------------------------------------------------------------------------------------
// What: writes the 6 face planes (mm, GPU packing, cut OUTSIDE the box; order -X, +X, -Y, +Y,
// -Z, +Z) into out[6] and returns 6 when the box crops, else writes nothing and returns 0.
- (NSUInteger)getClipPlanes:(simd_float4 *)out;

@end

NS_ASSUME_NONNULL_END
