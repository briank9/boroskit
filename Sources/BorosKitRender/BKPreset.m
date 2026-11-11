// BorosKitRender: BKPreset implementation (see BKPreset.h for the why).

/* BOROS OVERVIEW (plain language)
 * A "preset" is a saved look for the 3D view, such as a bone view or a soft-tissue
 * view. It records the colours, see-through settings, lighting and window brightness
 * and contrast that go with that look.
 * This file fills in those settings for one preset and lets a copy be edited without
 * changing the original. The renderer reads presets to decide how the 3D picture looks.
 */

#import "BKPreset.h"
#import "BKTransferFunction.h"
#import "BKVolumeTexture.h"

@implementation BKPresetCurve {
    NSData *_points; // BKPresetCurvePoint array, in the order stored in the preset
}

// Stores a copy of the curve's points.
- (instancetype)initWithPoints:(const BKPresetCurvePoint *)points count:(NSUInteger)count
{
    if ((self = [super init])) {
        _points = [NSData dataWithBytes:points length:count * sizeof(BKPresetCurvePoint)];
    }
    return self;
}

- (NSUInteger)pointCount { return _points.length / sizeof(BKPresetCurvePoint); }

// Returns one point (index must be < pointCount).
- (BKPresetCurvePoint)pointAtIndex:(NSUInteger)index
{
    NSParameterAssert(index < self.pointCount);
    return ((const BKPresetCurvePoint *)_points.bytes)[index];
}

@end

@implementation BKPreset

// Defaults match a freshly opened Horos VR window: "Default" lighting, parallel
// projection, black background, no CLUT, linear opacity.
- (instancetype)init
{
    if ((self = [super init])) {
        _name = @"";
        _advancedCurves = @[];
        _convolutionFilterNames = @[];
        _warnings = @[];
        _windowCenter = 40;
        _windowWidth = 400;
        _shadingEnabled = YES;
        _shadingName = @"Default";
        _ambient = 0.15f; _diffuse = 0.9f; _specular = 0.3f; _specularPower = 15;
        _horosProjectionMode = 1;
    }
    return self;
}

// NSCopying: presets are values; a copy can be edited without touching the original.
- (id)copyWithZone:(NSZone *)zone
{
    BKPreset *c = [[[self class] allocWithZone:zone] init];
    c.name = _name; c.groupName = _groupName;
    c.usesAdvancedCLUT = _usesAdvancedCLUT;
    c.clutName = _clutName; c.opacityName = _opacityName;
    c.clutRed = _clutRed; c.clutGreen = _clutGreen; c.clutBlue = _clutBlue;
    c.opacityPoints = _opacityPoints;
    c.advancedCurves = _advancedCurves;
    c.windowCenter = _windowCenter; c.windowWidth = _windowWidth;
    c.shadingEnabled = _shadingEnabled; c.shadingName = _shadingName;
    c.ambient = _ambient; c.diffuse = _diffuse; c.specular = _specular; c.specularPower = _specularPower;
    c.horosProjectionMode = _horosProjectionMode;
    c.backgroundRed = _backgroundRed; c.backgroundGreen = _backgroundGreen; c.backgroundBlue = _backgroundBlue;
    c.convolutionFilterNames = _convolutionFilterNames;
    c.warnings = _warnings;
    return c;
}

// Horos mode 1 is VTK's parallel projection; 0 and 2 are perspective.
- (BKProjection)projection
{
    return _horosProjectionMode == 1 ? BKProjectionOrthographic : BKProjectionPerspective;
}

// Same view angles as -[VRView setProjectionMode:]: 60° for mode 2, otherwise 30°.
- (CGFloat)fieldOfView
{
    return _horosProjectionMode == 2 ? 60.0 : 30.0;
}

- (BKTransferFunction *)transferFunction
{
    return [self transferFunctionWithWindowCenter:_windowCenter windowWidth:_windowWidth];
}

- (BKTransferFunction *)transferFunctionWithWindowCenter:(float)windowCenter windowWidth:(float)windowWidth
{
    if (_usesAdvancedCLUT)
        return [self transferFunctionForVolumeMinimum:NAN volumeMaximum:NAN];
    return [self simpleTransferFunctionWithWindowCenter:windowCenter windowWidth:windowWidth];
}

- (BKTransferFunction *)transferFunctionForVolumeMinimum:(float)volumeMinimum volumeMaximum:(float)volumeMaximum
{
    if (!_usesAdvancedCLUT)
        return [self simpleTransferFunctionWithWindowCenter:_windowCenter windowWidth:_windowWidth];
    return [self advancedTransferFunctionForVolumeMinimum:volumeMinimum volumeMaximum:volumeMaximum];
}

// Simple preset -> function, like -[VRView setCLUT:::] + -[VRView setOpacity:].
// "No CLUT" is the 0..255 gray ramp VRView builds itself when the CLUT is nil.
- (BKTransferFunction *)simpleTransferFunctionWithWindowCenter:(float)windowCenter windowWidth:(float)windowWidth
{
    uint8_t gray[256];
    for (int i = 0; i < 256; i++) gray[i] = (uint8_t)i;

    BOOL hasCLUT = _clutRed.length >= 256 && _clutGreen.length >= 256 && _clutBlue.length >= 256;
    const uint8_t *r = hasCLUT ? _clutRed.bytes : gray;
    const uint8_t *g = hasCLUT ? _clutGreen.bytes : gray;
    const uint8_t *b = hasCLUT ? _clutBlue.bytes : gray;

    NSUInteger count = _opacityPoints.length / sizeof(CGPoint);
    return [BKTransferFunction transferFunctionWithCLUTRed:r green:g blue:b
                                              windowCenter:windowCenter windowWidth:windowWidth
                                             opacityPoints:count ? _opacityPoints.bytes : NULL
                                                     count:count];
}

// Advanced preset -> function, like -[VRView setAdvancedCLUT:lowResolution:]:
//   opacityTransferFunction->AddSegment(volumeMin, 0, volumeMax, 0);
//   for each curve point: AddRGBPoint(x, r, g, b); AddPoint(x, y * y);
// Both are then interpolated linearly and clamped, which BKTransferFunction does too.
// Without a volume range (NaN) the 0-opacity anchors are simply left out.
- (BKTransferFunction *)advancedTransferFunctionForVolumeMinimum:(float)volumeMinimum volumeMaximum:(float)volumeMaximum
{
    BKTransferFunction *tf = [[BKTransferFunction alloc] init];
    if (isfinite(volumeMinimum) && isfinite(volumeMaximum)) {
        [tf addOpacityPointAtValue:volumeMinimum opacity:0];
        [tf addOpacityPointAtValue:volumeMaximum opacity:0];
    }
    for (BKPresetCurve *curve in _advancedCurves) {
        for (NSUInteger i = 0; i < curve.pointCount; i++) {
            BKPresetCurvePoint p = [curve pointAtIndex:i];
            [tf addColorPointAtValue:p.value red:p.red green:p.green blue:p.blue];
            [tf addOpacityPointAtValue:p.value opacity:p.level * p.level];
        }
    }
    return tf;
}

// Applies colour/opacity, WL/WW, lighting and projection - what VRController's
// "apply preset" does - but leaves mode, camera and cropping to the caller.
- (void)applyToRenderer:(BKVolumeRenderer *)renderer
{
    BKVolumeTexture *volume = renderer.volumeTexture;
    float lo = volume ? volume.minimumValue : NAN;
    float hi = volume ? volume.maximumValue : NAN;

    renderer.transferFunction = [self transferFunctionForVolumeMinimum:lo volumeMaximum:hi];
    renderer.windowCenter = _windowCenter;
    renderer.windowWidth = _windowWidth;

    renderer.shadingEnabled = _shadingEnabled;
    renderer.ambient = _ambient;
    renderer.diffuse = _diffuse;
    renderer.specular = _specular;
    renderer.specularPower = _specularPower;

    renderer.projection = self.projection;
    renderer.fieldOfView = self.fieldOfView;
}

@end
