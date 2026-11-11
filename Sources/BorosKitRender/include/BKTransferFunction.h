// BorosKitRender: BKTransferFunction
//
// What it is: the "colour and see-through-ness" rule for 3D volume rendering. For each
// CT value it says what colour that tissue is drawn in and how opaque it is
// (e.g. air = invisible, soft tissue = faint red, bone = solid white).
//
// Why it looks like this: Horos stores its presets in two styles, and this class can
// hold both so the existing presets can be carried over later without loss:
//   1. "Simple" presets: a 256-entry colour table (CLUT) stretched across the current
//      window, plus an opacity curve whose x runs 0..256 across that same window.
//      -> +transferFunctionWithCLUTRed:green:blue:windowCenter:windowWidth:opacityPoints:count:
//   2. "Advanced" presets: colour and opacity points placed directly at CT values.
//      -> -addColorPointAtValue:... and -addOpacityPointAtValue:...
// Colour and opacity are kept as separate point lists, exactly like VTK's
// vtkColorTransferFunction / vtkPiecewiseFunction that Horos uses today, and both are
// interpolated linearly between points and clamped to the end values outside them
// (VTK's default behaviour).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BKTransferFunction : NSObject <NSCopying>

// Number of colour / opacity points currently defined.
@property (nonatomic, readonly) NSUInteger colorPointCount;
@property (nonatomic, readonly) NSUInteger opacityPointCount;

// Lowest and highest CT value used by any point. The renderer bakes the function over
// exactly this range; values outside it take the end values (clamping).
@property (nonatomic, readonly) float minimumValue;
@property (nonatomic, readonly) float maximumValue;

// Adds a colour (components 0..1) at a CT value. Points may be added in any order.
- (void)addColorPointAtValue:(float)value red:(float)red green:(float)green blue:(float)blue;

// Adds an opacity (0..1) at a CT value. Points may be added in any order.
- (void)addOpacityPointAtValue:(float)value opacity:(float)opacity;

// Clears both lists.
- (void)removeAllPoints;

// Evaluates the function at one value: writes r, g, b, a (all 0..1) into rgba.
// With no colour points the colour is white; with no opacity points the opacity is 1.
- (void)getRGBA:(float[_Nonnull 4])rgba atValue:(float)value;

// Samples the function at `count` evenly spaced values from minimumValue to
// maximumValue into `rgba` (count * 4 floats). This is what gets uploaded to the GPU.
- (void)bakeIntoRGBA:(float *)rgba count:(NSUInteger)count;

// A black-to-white ramp with opacity rising from 0 to 1 between `low` and `high`.
// Handy default and used by the tests.
+ (instancetype)grayscaleRampFromValue:(float)low toValue:(float)high;

// Builds a function the way Horos' -[VRView setCLUT:::] + -[VRView setOpacity:] do:
//  - red/green/blue: 256-entry colour table (0..255) spread over [wl - ww/2, wl + ww/2]
//  - opacityPoints: Horos opacity curve points with x in 0..256 across the window
//    (Horos stores them as strings with x offset by +1000; pass x with that 1000
//    already removed) and y = opacity 0..1. May be NULL/0 for "linear ramp".
//  Like Horos, a 0-opacity point is added at the window start if the curve does not
//  start at 0, and an opacity-1 point at the window end if it does not end at 256.
//  (Horos also divides opacity by its super-sampling factor; this engine instead
//   corrects opacity for the actual sample spacing, see opacityUnitDistance.)
+ (instancetype)transferFunctionWithCLUTRed:(const uint8_t *)red
                                      green:(const uint8_t *)green
                                       blue:(const uint8_t *)blue
                               windowCenter:(float)windowCenter
                                windowWidth:(float)windowWidth
                              opacityPoints:(const CGPoint * _Nullable)opacityPoints
                                      count:(NSUInteger)count;

@end

NS_ASSUME_NONNULL_END
