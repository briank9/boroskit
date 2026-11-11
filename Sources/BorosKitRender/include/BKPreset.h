// BorosKitRender: BKPreset
//
// What it is: one 3D "look" from the Horos/Boros VR window (Standard, Bone + Skin,
// Glossy, Vascular...), fully resolved and ready to apply to the Metal renderer.
// It holds everything a Horos preset file describes: the colour table (CLUT), the
// opacity curve, the window level/width, the lighting ("shading") and the camera
// projection. Use BKPresetLoader to read one from a preset file.
//
// Why it exists: the Metal engine has to show the same pictures as the VTK-based VR
// window, so radiologists and surgeons keep the looks they already know. This class
// reproduces, step for step, what -[VRController applyPreset:] + -[VRView setCLUT:::],
// -[VRView setOpacity:], -[VRView setAdvancedCLUT:lowResolution:] and
// -[VRView setShadingValues::::] do with VTK.
//
// Two kinds of preset exist in Horos:
//   - "Simple": a 256-entry colour table and an opacity curve, both stretched across
//     the window [wl - ww/2, wl + ww/2]. Changing WL/WW moves the whole look.
//   - "Advanced" (16-bit CLUT): colour + opacity points placed directly at CT values
//     (HU), in one or more curves. WL/WW is not used for these.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "BKVolumeRenderer.h"

@class BKTransferFunction;

NS_ASSUME_NONNULL_BEGIN

// One control point of an advanced (16-bit) CLUT curve.
// value: CT value (HU). level: the curve height 0..1 as drawn in Horos' CLUT editor
// (the opacity used is level * level, exactly as VRView does). red/green/blue: 0..1.
typedef struct {
    float value;
    float level;
    float red, green, blue;
} BKPresetCurvePoint;

// One advanced-CLUT curve (a "trapezoid" in Horos' CLUT editor).
@interface BKPresetCurve : NSObject
@property (nonatomic, readonly) NSUInteger pointCount;
- (BKPresetCurvePoint)pointAtIndex:(NSUInteger)index;
- (instancetype)initWithPoints:(const BKPresetCurvePoint *)points count:(NSUInteger)count;
@end

@interface BKPreset : NSObject <NSCopying>

// --- Identity (as shown in the VR window's preset browser) -------------------------
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *groupName;

// --- Colour & opacity ----------------------------------------------------------------
// YES = advanced 16-bit CLUT (advancedCurves), NO = simple CLUT + opacity table.
@property (nonatomic) BOOL usesAdvancedCLUT;

// Names exactly as written in the preset file (e.g. "VR Muscles-Bones",
// "Logarithmic Inverse Table", "16-bit CLUT"), kept for display and saving.
@property (nonatomic, copy, nullable) NSString *clutName;
@property (nonatomic, copy, nullable) NSString *opacityName;

// Simple presets: 256-entry colour table, each NSData = 256 bytes (0..255).
// nil = "No CLUT" (Horos then uses a black-to-white ramp).
@property (nonatomic, copy, nullable) NSData *clutRed;
@property (nonatomic, copy, nullable) NSData *clutGreen;
@property (nonatomic, copy, nullable) NSData *clutBlue;

// Simple presets: opacity curve points (CGPoint array as NSData), x in 0..256 across
// the window (Horos' +1000 offset already removed), y = opacity 0..1.
// Empty / nil = "Linear Table" (opacity ramps from 0 to 1 across the window).
@property (nonatomic, copy, nullable) NSData *opacityPoints;

// Advanced presets: the curves, CT values in HU.
@property (nonatomic, copy) NSArray<BKPresetCurve *> *advancedCurves;

// Window level / width (HU). For simple presets this positions the CLUT and opacity
// curve; for advanced presets Horos derives it from the first curve (informational).
@property (nonatomic) float windowCenter;
@property (nonatomic) float windowWidth;

// --- Lighting ----------------------------------------------------------------------
@property (nonatomic) BOOL shadingEnabled;
@property (nonatomic, copy, nullable) NSString *shadingName;   // e.g. "Default", "Glossy Bone"
@property (nonatomic) float ambient;
@property (nonatomic) float diffuse;
@property (nonatomic) float specular;
@property (nonatomic) float specularPower;

// --- Camera / background -------------------------------------------------------------
// Horos projection mode: 0 = perspective 30°, 1 = parallel (orthographic),
// 2 = perspective 60° ("endoscopy"-like wide angle).
@property (nonatomic) int horosProjectionMode;
@property (nonatomic, readonly) BKProjection projection;     // derived from horosProjectionMode
@property (nonatomic, readonly) CGFloat fieldOfView;        // degrees, derived (30 or 60)

// Background colour of the 3D view (0..1). The renderer blends over transparent
// black (alpha in rgba8Data), so the display layer paints this colour behind it.
@property (nonatomic) float backgroundRed;
@property (nonatomic) float backgroundGreen;
@property (nonatomic) float backgroundBlue;

// Names of the 2D convolution filters the preset asks for (e.g. "Basic Smooth 5x5").
// Kept but NOT applied by the Metal engine yet (Horos smooths the volume before VTK).
@property (nonatomic, copy) NSArray<NSString *> *convolutionFilterNames;

// Anything the loader could not resolve (unknown CLUT/opacity/shading name...). The
// preset still loads using the same fallback Horos uses; these explain what happened.
@property (nonatomic, copy) NSArray<NSString *> *warnings;

// --- Building the colour/opacity function -----------------------------------------

// Simple presets: the function at the preset's own WL/WW.
// Advanced presets: needs the volume's value range (see below); this variant uses the
// curves' own extent instead, which differs from VTK only between the curves' ends and
// the volume's minimum/maximum.
- (BKTransferFunction *)transferFunction;

// Simple presets: the function at another WL/WW (what happens when the user drags
// WL/WW in the VR window). Advanced presets ignore the window, like Horos.
- (BKTransferFunction *)transferFunctionWithWindowCenter:(float)windowCenter
                                             windowWidth:(float)windowWidth;

// Exactly what VRView builds. For advanced presets Horos first sets opacity 0 over the
// whole volume range [volumeMinimum, volumeMaximum] and then adds the curve points,
// so opacity ramps between curves and from the outermost points down to 0 at the
// volume's extremes. Simple presets ignore the range.
- (BKTransferFunction *)transferFunctionForVolumeMinimum:(float)volumeMinimum
                                           volumeMaximum:(float)volumeMaximum;

// Applies the whole preset to a renderer: transfer function (using the renderer's
// current volume range for advanced presets), WL/WW, lighting and projection.
// Does not change the render mode, camera position or crop box.
- (void)applyToRenderer:(BKVolumeRenderer *)renderer;

@end

NS_ASSUME_NONNULL_END
