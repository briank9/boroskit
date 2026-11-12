// BorosKitDisplay: BKImage + BKImageLayerRenderer
//
// What it is: the GPU (Metal) drawing of one 2D grayscale/float image — a CT slice, an
// MPR slab, a panorex — with window/level, an optional colour table (CLUT), zoom, pan,
// rotation, flips and nearest/linear interpolation.
//
// Why: Horos' DCMView draws images with old OpenGL (about 440 direct GL calls), which is
// deprecated on the Mac and unavailable in a modern iPad app. This renderer does the same
// job with Metal, which works on both. It keeps the full 32-bit float pixel values on
// the GPU, so window/level is applied to the real CT numbers (no 8-bit pre-quantising).
//
// It is platform-neutral: it draws into any Metal texture — a CAMetalLayer drawable
// (BKImageView on Mac or iPad) or an offscreen texture (tests, exports, thumbnails).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import "BKViewTransform.h"
#import "N3Geometry.h"

// C functions here keep C names when this header is used from C++ (Objective-C++ app
// code such as the VTK -> Metal mirror), so they link (added 2026-11-12).
#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// One 2D image to display: float pixel values (e.g. Hounsfield units), row 0 = top.
@interface BKImage : NSObject

// Copies `width * height` floats. Spacing in mm (used for the non-square-pixel correction
// and the scale bar).
- (instancetype)initWithFloatPixels:(const float *)pixels width:(NSUInteger)width height:(NSUInteger)height
                      pixelSpacingX:(double)spacingX pixelSpacingY:(double)spacingY;

// Same, wrapping existing data (must hold width*height floats).
- (instancetype)initWithFloatData:(NSData *)data width:(NSUInteger)width height:(NSUInteger)height
                    pixelSpacingX:(double)spacingX pixelSpacingY:(double)spacingY;

// Colour picture, already finished (RGBA, 8 bits per channel, row 0 = top; alpha ignored
// unless the renderer's usesImageAlpha is YES).
// The renderer only places it on screen (zoom, pan, rotate, flip, smoothing); window/level,
// colour table and invert are NOT applied.
// Why (Boros 6): colour photos, screen captures and the other special images that Horos
// already turns into a finished picture can then be shown by Metal instead of OpenGL.
// floatData is empty for such an image and -valueAtX:y: returns 0.
- (instancetype)initWithRGBA8Data:(NSData *)data width:(NSUInteger)width height:(NSUInteger)height
                    pixelSpacingX:(double)spacingX pixelSpacingY:(double)spacingY;
@property (nonatomic, readonly) BOOL isColor;            // YES = made with -initWithRGBA8Data:...
@property (nonatomic, readonly, nullable) NSData *rgbaData; // the RGBA8 bytes of a colour image
@property (nonatomic, readonly) NSData *floatData;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double pixelSpacingX;
@property (nonatomic, readonly) double pixelSpacingY;

// Optional patient-space geometry (mm), carried along for later use (cross-reference
// lines, 3D cursors). Not used for drawing. Defaults: origin 0, rows along +x, columns +y.
@property (nonatomic) N3Vector origin;
@property (nonatomic) N3Vector rowDirection;
@property (nonatomic) N3Vector columnDirection;

// Value of pixel (x from the left, y from the top); for tests and pixel-value readouts.
- (float)valueAtX:(NSUInteger)x y:(NSUInteger)y;

@end

typedef NS_ENUM(int32_t, BKImageInterpolation) {
    BKImageInterpolationNearest = 0, // blocky pixels (exact values; Horos "no smoothing")
    BKImageInterpolationLinear  = 1, // bilinear (smooth when zoomed in)
};

typedef struct {
    float red, green, blue, alpha; // 0..1
} BKColor;

static inline BKColor BKColorMake(float r, float g, float b, float a) { BKColor c = { r, g, b, a }; return c; }

@interface BKImageLayerRenderer : NSObject

// nil device = the system default GPU. Returns nil (with error) if Metal is unavailable.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device error:(NSError **)error;

@property (nonatomic, readonly) id<MTLDevice> device;

// The image to show. Setting it uploads the pixels to the GPU (32-bit float texture).
@property (nonatomic, strong, nullable) BKImage *image;

// Window/level in pixel units (e.g. HU): values <= center - width/2 are black,
// >= center + width/2 white, linear in between (same rule as Horos DCMView).
@property (nonatomic) double windowCenter;
@property (nonatomic) double windowWidth;

// Optional colour table: 256 entries of R,G,B bytes (768 bytes), applied after
// window/level (index 0 = low end). nil = grayscale.
@property (nonatomic, copy, nullable) NSData *colorTable;

@property (nonatomic) BOOL invert;                         // swap black and white
@property (nonatomic) BKImageInterpolation interpolation;  // default nearest
@property (nonatomic) BKColor backgroundColor;             // outside the image; default opaque black

// Where the image sits in the view. Its imageWidth/Height are kept in sync with `image`
// by the renderer when an image is set (the rest is up to the caller).
@property (nonatomic) BKViewTransform viewTransform;

// --- Overlay layer (fusion) ---------------------------------------------------------
// What: an optional second renderer whose image is drawn ON TOP of this one, in the same
// pass, blended with the overlay image's own alpha (result = overlay * a + below * (1 - a);
// the result keeps the alpha of what is below). The overlay keeps its own image,
// window/level, colour table, interpolation and view transform, so the two images can
// have different sizes and positions. Outside the overlay image nothing is drawn (its
// background is ignored). An overlay's own overlay is ignored.
// Why (Boros 6): Horos "fusion" lays a second series (for example a coloured PET or a
// second CT) over the first with an adjustable transparency. Horos makes that second
// series into a finished colour picture whose alpha holds the per-pixel transparency;
// with this, Metal can show it without OpenGL.
// The overlay must use the same Metal device as this renderer.
@property (nonatomic, strong, nullable) BKImageLayerRenderer *overlay;

// YES = a colour image (-[BKImage initWithRGBA8Data:...]) keeps its alpha channel instead
// of being treated as opaque. Set it on an overlay renderer whose picture carries
// transparency. Default NO (alpha ignored, as before).
@property (nonatomic) BOOL usesImageAlpha;

// Encodes drawing into `texture` (e.g. a CAMetalLayer drawable texture). `scale` is
// device pixels per view point (the layer's contentsScale). Clears to the background.
- (BOOL)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer texture:(id<MTLTexture>)texture
                        scale:(CGFloat)scale error:(NSError **)error;

// Renders synchronously into an offscreen RGBA8 image of the given size in device pixels
// (with scale 1, one pixel per view point). Returns width*height*4 bytes, row 0 = top.
// For tests, thumbnails and screenshots.
- (nullable NSData *)renderRGBA8WithWidth:(NSUInteger)width height:(NSUInteger)height
                                    scale:(CGFloat)scale error:(NSError **)error;

// A command queue owned by the renderer, for callers that don't have one (BKImageView).
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
