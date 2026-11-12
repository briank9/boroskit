// BorosKitDisplay: overlays (ROIs, the panorex curve, crosshairs, measurements, labels)
//
// What it is: a small set of drawable shapes whose geometry is stored in IMAGE pixel
// coordinates, drawn with CoreGraphics into a view-space context through the same
// BKViewTransform as the image.
//
// Why: in Horos, ROIs and curves are drawn with OpenGL (ROI.m alone has ~350 GL calls).
// CoreGraphics works identically on Mac and iPad, draws crisp anti-aliased lines and
// text, and needs no GPU code. Because every item is converted with the image's own
// transform at draw time, overlays stay locked to the anatomy under zoom, pan, rotation
// and flips. Line widths, handle sizes and font sizes are in view points, so they stay
// readable at any zoom (as in Horos).
//
// Drawing contract: the CGContext passed to -drawInContext:transform: has view
// coordinates with the origin at the top-left and y down (BKImageView sets that up).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "BKViewTransform.h"
#import "BKImageLayerRenderer.h"   // BKColor
#import "N3Geometry.h"

@class N3BezierPath;

NS_ASSUME_NONNULL_BEGIN

// Base class: style shared by all overlay items.
@interface BKOverlayItem : NSObject
@property (nonatomic) BKColor strokeColor;   // default yellow
@property (nonatomic) BKColor fillColor;     // default fully transparent (no fill)
@property (nonatomic) CGFloat lineWidth;     // view points, default 1.5
@property (nonatomic) BOOL dashed;
@property (nonatomic) BOOL hidden;
@property (nonatomic, copy, nullable) NSString *identifier; // free for the app (e.g. ROI id)

// Draws the item. `context` is in view points, origin top-left, y down.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform;

// Distance in view points from `viewPoint` to the item's outline (for clicking/tapping
// ROIs and handles). Large values mean "not near". Base class: CGFLOAT_MAX.
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform;
@end

// A straight segment (measurements, crosshair lines).
@interface BKOverlayLine : BKOverlayItem
+ (instancetype)lineFrom:(CGPoint)start to:(CGPoint)end;
@property (nonatomic) CGPoint start;  // image pixels
@property (nonatomic) CGPoint end;
@end

// Connected points: open polylines and closed polygons (freehand / polygon ROIs).
@interface BKOverlayPolyline : BKOverlayItem
+ (instancetype)polylineWithPoints:(const CGPoint *)points count:(NSUInteger)count closed:(BOOL)closed;
@property (nonatomic, readonly) NSUInteger pointCount;
@property (nonatomic) BOOL closed;
- (CGPoint)pointAtIndex:(NSUInteger)index;
@end

// A smooth curve (the panorex/CPR curve, Bezier ROIs), stored as a CGPath in image pixels.
@interface BKOverlayCurve : BKOverlayItem
// Takes ownership of a copy of `path` (in image pixel coordinates).
+ (instancetype)curveWithImagePath:(CGPathRef)path;
// Converts an N3BezierPath (e.g. the CPR curve in patient mm) to image pixels with
// `patientToImage` (x, y of the result are used; z is ignored). Curves are kept as curves.
+ (instancetype)curveWithBezierPath:(N3BezierPath *)bezierPath patientToImage:(N3AffineTransform)patientToImage;
@property (nonatomic, readonly) CGPathRef imagePath;
@end

// A point marker / editing handle: a small dot of fixed on-screen size.
@interface BKOverlayPoint : BKOverlayItem
+ (instancetype)pointAt:(CGPoint)position;
@property (nonatomic) CGPoint position;  // image pixels
@property (nonatomic) CGFloat radius;    // view points, default 4
@property (nonatomic) BOOL filled;       // default YES (uses strokeColor)
@end

// Axis-aligned (in image space) rectangle or ellipse ROI. When the view is rotated they
// rotate with the image.
@interface BKOverlayRect : BKOverlayItem
+ (instancetype)rectWithImageRect:(CGRect)rect ellipse:(BOOL)ellipse;
@property (nonatomic) CGRect imageRect;
@property (nonatomic) BOOL ellipse;
@end

// A text label anchored to an image point; stays upright and fixed-size on screen.
// Where the text sits relative to its anchor (after `offset`). Why: labels copied from
// another program (e.g. the 3D views' orientation letters, centred at the bottom edge or
// right-aligned at the right edge) must keep their placement rules.
typedef NS_ENUM(NSInteger, BKTextHorizontalAlignment) {
    BKTextAlignLeft = 0,     // anchor at the left end (default)
    BKTextAlignCenter = 1,
    BKTextAlignRight = 2,
};
typedef NS_ENUM(NSInteger, BKTextVerticalAlignment) {
    BKTextAlignBaseline = 0, // anchor on the baseline (default)
    BKTextAlignTop = 1,      // anchor at the top of the letters (ascent)
    BKTextAlignMiddle = 2,
    BKTextAlignBottom = 3,   // anchor at the bottom of the letters (descent)
};

@interface BKOverlayText : BKOverlayItem
+ (instancetype)text:(NSString *)text at:(CGPoint)anchor;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGPoint anchor;          // image pixels
@property (nonatomic) CGFloat fontSize;        // view points, default 12
@property (nonatomic) CGPoint offset;          // view points added after transforming (e.g. 6, -6)
@property (nonatomic) BOOL drawsBackground;    // dark box behind the text for legibility
@property (nonatomic) BKTextHorizontalAlignment horizontalAlignment;   // default left
@property (nonatomic) BKTextVerticalAlignment verticalAlignment;       // default baseline
@property (nonatomic) BOOL bold;               // default NO
@property (nonatomic) BOOL shadow;             // dark copy 1 point down-right behind the text, default NO
@end

// A scale bar in a view corner showing a round length in mm (like Horos' ruler).
// View-anchored: it does not move with the image, but its length follows the zoom.
@interface BKOverlayScaleBar : BKOverlayItem
+ (instancetype)scaleBar;
@property (nonatomic) CGFloat margin;            // view points from the bottom-left corner, default 16
@property (nonatomic) CGFloat targetLength;      // preferred on-screen length in points, default 100
// The length (mm) the bar shows for `transform`, chosen from 1-2-5 steps. 0 if unknown.
- (CGFloat)lengthInMillimetresForTransform:(BKViewTransform)transform;
@end

// Draws `items` in order (later items on top), skipping hidden ones.
void BKDrawOverlays(CGContextRef context, NSArray<BKOverlayItem *> *items, BKViewTransform transform);

// Returns the visible item nearest to `viewPoint` within `tolerance` view points
// (topmost wins on ties), or nil. For click/tap selection of ROIs and handles.
BKOverlayItem * _Nullable BKOverlayHitTest(NSArray<BKOverlayItem *> *items, CGPoint viewPoint,
                                           CGFloat tolerance, BKViewTransform transform);

NS_ASSUME_NONNULL_END
