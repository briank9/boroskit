// BorosKitDisplay: BKViewTransform
//
// What it is: the one description of "where the image sits on screen" — zoom, pan,
// rotation, flips and the non-square-pixel correction — plus pure functions that convert
// points between image pixels and view points.
//
// Why it exists: the old Horos DCMView (OpenGL) applies zoom/pan/rotate in several places
// (the GL matrix for the image, separate math for ROIs, crosshairs, the mouse). Here the
// image shader, the overlay drawing (ROIs, panorex curve, measurements) and mouse/touch
// handling all use the SAME transform, so overlays can never drift off the anatomy.
//
// Coordinate conventions (both y-down, origin top-left, like the DICOM pixel grid):
//   - image coordinates: pixels. Pixel (i, j) covers [i, i+1) x [j, j+1); its centre is
//     (i + 0.5, j + 0.5). x to the right, y down.
//   - view coordinates: points (not device pixels). (0,0) is the top-left of the view,
//     y down. BKImageView makes the macOS NSView flipped so this holds on Mac and iPad.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    CGFloat imageWidth;      // image size in pixels
    CGFloat imageHeight;
    CGFloat pixelSpacingX;   // mm per pixel (only the ratio Y/X matters for display)
    CGFloat pixelSpacingY;
    CGFloat viewWidth;       // view size in points
    CGFloat viewHeight;
    CGFloat zoom;            // view points per image pixel along x (1 = one pixel per point)
    CGFloat panX;            // offset of the image centre from the view centre, in view points
    CGFloat panY;
    CGFloat rotationDegrees; // clockwise on screen
    BOOL flipHorizontal;     // mirror left/right (applied before rotation, in image orientation)
    BOOL flipVertical;       // mirror top/bottom
} BKViewTransform;

// Makes a transform that shows the whole image centred in the view (zoom-to-fit), no
// rotation or flips, square-pixel spacing 1 x 1 unless changed afterwards.
BKViewTransform BKViewTransformMakeFit(CGFloat imageWidth, CGFloat imageHeight, CGFloat viewWidth, CGFloat viewHeight);

// Zoom factor at which the whole (rotated, aspect-corrected) image fits inside the view.
CGFloat BKViewTransformFitZoom(BKViewTransform t);

// Image pixels -> view points, as a CGAffineTransform (usable directly with CoreGraphics).
CGAffineTransform BKViewTransformImageToView(BKViewTransform t);

// View points -> image pixels (the exact inverse of the above).
CGAffineTransform BKViewTransformViewToImage(BKViewTransform t);

// Convenience point conversions.
CGPoint BKViewTransformImagePointToView(BKViewTransform t, CGPoint imagePoint);
CGPoint BKViewTransformViewPointToImage(BKViewTransform t, CGPoint viewPoint);

// Physical size (mm) of one view point along the image's x axis at the current zoom;
// used by the scale bar and by measurements shown in view units.
CGFloat BKViewTransformMillimetresPerViewPoint(BKViewTransform t);

// Returns a copy zoomed by `factor` while keeping the image point under `viewPoint`
// fixed on screen (what pinch-to-zoom and scroll-wheel zoom need).
BKViewTransform BKViewTransformZoomedAroundViewPoint(BKViewTransform t, CGFloat factor, CGPoint viewPoint);

NS_ASSUME_NONNULL_END
