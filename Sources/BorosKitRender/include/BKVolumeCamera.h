// BorosKitRender: BKVolumeCamera
//
// What it is: the camera of the interactive 3D view, as pure math (no window, no
// mouse/touch code). It keeps a focal point (what you look at), a viewing direction,
// an "up" direction, a distance and a zoom, and offers the moves the VR window offers:
// trackball rotate, pan, zoom, roll, reset, and the standard views (front, left side...).
//
// Why separate from the view: the same camera drives the Mac view and the iPad view,
// and its math can be unit-tested without a screen. It follows VTK's vtkCamera
// conventions (focal point, distance, parallel scale = half the image height in mm,
// view angle) so the Horos VR window's numbers carry over.
//
// Coordinates: patient (DICOM) millimetres — x to the patient's left, y to the
// posterior (back), z to the head — the same space as the rest of BorosKit.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "N3Geometry.h"
#import "BKVolumeRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// The standard view directions. Names say where the CAMERA is (what side of the
// patient you look at). The first four match the Horos VR window's buttons:
//   Anterior  = Horos "coView"         (camera in front, head up)
//   Left      = Horos "saView"         (camera at the patient's left, head up; Horos' reset view)
//   Right     = Horos "saViewOpposite" (camera at the patient's right, head up)
//   Inferior  = Horos "axView"         (camera at the feet looking up, anterior at the top)
// Posterior and Superior are the two missing opposites, with the same "up" rules.
typedef NS_ENUM(NSInteger, BKStandardView) {
    BKStandardViewAnterior = 0,
    BKStandardViewPosterior,
    BKStandardViewLeft,
    BKStandardViewRight,
    BKStandardViewSuperior,
    BKStandardViewInferior,
};

@interface BKVolumeCamera : NSObject <NSCopying>

// The point the camera looks at and rotates around (patient mm).
@property (nonatomic) N3Vector focalPoint;
// Unit viewing direction (from the camera toward the focal point).
@property (nonatomic, readonly) N3Vector direction;
// Unit "up" direction, always perpendicular to `direction`.
@property (nonatomic, readonly) N3Vector viewUp;
// Distance from the eye to the focal point (mm). Only matters for perspective.
@property (nonatomic) CGFloat distance;
// Orthographic zoom: half the visible image height in mm (VTK's ParallelScale).
@property (nonatomic) CGFloat parallelScale;
@property (nonatomic) BKProjection projection;
// Perspective: vertical view angle in degrees (Horos: 30, or 60 for wide angle).
@property (nonatomic) CGFloat viewAngle;

// Eye position = focalPoint - direction * distance.
@property (nonatomic, readonly) N3Vector position;

// Sets direction and up together; up is made perpendicular to the direction.
// Returns NO (and changes nothing) if they are parallel or zero.
- (BOOL)setDirection:(N3Vector)direction viewUp:(N3Vector)viewUp;

// Fits the camera to a box (patient mm) like VTK's ResetCamera: focal point at the
// box centre, parallelScale = the box's bounding-sphere radius, and a distance that
// shows the whole sphere in perspective. Keeps direction and up.
- (void)resetToBoxMin:(N3Vector)boxMin max:(N3Vector)boxMax;

// Turns the camera to a standard view, keeping focal point, distance and zoom (exactly
// what the Horos buttons do: "apply the same zoom").
- (void)showStandardView:(BKStandardView)view;

// Unit direction and up of a standard view (for tests and UI).
+ (void)getStandardView:(BKStandardView)view direction:(N3Vector *)direction viewUp:(N3Vector *)viewUp;

// --- Moves (angles in degrees, distances in view points) -------------------------
// Rotate the camera around the focal point about the view-up axis (VTK Azimuth).
- (void)azimuth:(CGFloat)degrees;
// Rotate the camera around the focal point about the horizontal screen axis
// (VTK Elevation), turning "up" along so it never degenerates near the poles.
- (void)elevation:(CGFloat)degrees;
// Spin the image around the viewing direction (VTK Roll).
- (void)roll:(CGFloat)degrees;

// Trackball rotation for a drag of (dx, dy) view points in a view of `viewSize`
// (y down). Same feel as VTK's trackball camera: dragging across the full width turns
// the volume 200 degrees.
- (void)rotateByViewDelta:(CGSize)delta viewSize:(CGSize)viewSize;

// Pans so the volume follows the pointer: a drag of (dx, dy) view points moves the
// focal point (and eye) in the image plane by the matching number of mm at the focal
// plane. y down.
- (void)panByViewDelta:(CGSize)delta viewSize:(CGSize)viewSize;

// Zooms by `factor` (> 1 = closer / larger). Orthographic: divides parallelScale;
// perspective: moves the eye toward the focal point (VTK Dolly), as Horos' scroll
// wheel does.
- (void)zoomByFactor:(CGFloat)factor;

// Millimetres at the focal plane per view point, for a view `viewHeight` points tall.
- (CGFloat)millimetresPerViewPointForViewHeight:(CGFloat)viewHeight;

// Copies the camera into a renderer for an image of the given aspect (width/height).
- (void)applyToRenderer:(BKVolumeRenderer *)renderer aspectRatio:(CGFloat)aspectRatio;

@end

NS_ASSUME_NONNULL_END
