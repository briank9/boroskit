// BorosKitRender: BKTransferFunction implementation (see the header for the why).

/* BOROS OVERVIEW (plain language)
 * The transfer function is the rule that says how each tissue density in the scan is
 * coloured and how see-through it is. For example, dense bone can be made white and
 * solid while soft tissue is dim and transparent.
 * This file stores those colour and opacity points in order, and it makes copies so a
 * picture already being drawn is not changed by later edits. The renderer turns these
 * points into a lookup table the graphics chip reads for every sample.
 */

#import "BKTransferFunction.h"
#import "BKRenderCore.h"
#import "BKRenderParamsCore.h"   // preset (CLUT) -> points, 2026-11-26   // the evaluation/baking maths, shared with a future Vulkan backend

// One control point: a CT value and up to three components (r,g,b for colour points,
// just [0] = opacity for opacity points). Same type as the plain-C core uses.
typedef BKRenderTFPoint BKTFPoint;

@implementation BKTransferFunction {
    NSMutableData *_colorPoints;   // BKTFPoint array, kept sorted by value
    NSMutableData *_opacityPoints; // BKTFPoint array, kept sorted by value
}

// Creates an empty function (white, fully opaque everywhere until points are added).
- (instancetype)init
{
    if ((self = [super init])) {
        _colorPoints = [NSMutableData data];
        _opacityPoints = [NSMutableData data];
    }
    return self;
}

// NSCopying: renderers keep their own copy so later edits by the caller can't change
// a render that is already queued.
- (id)copyWithZone:(NSZone *)zone
{
    BKTransferFunction *copy = [[[self class] allocWithZone:zone] init];
    copy->_colorPoints = [_colorPoints mutableCopy];
    copy->_opacityPoints = [_opacityPoints mutableCopy];
    return copy;
}

- (NSUInteger)colorPointCount { return _colorPoints.length / sizeof(BKTFPoint); }
- (NSUInteger)opacityPointCount { return _opacityPoints.length / sizeof(BKTFPoint); }

// Inserts a point keeping the array sorted by value; a point at an existing value
// replaces it (same as VTK's AddPoint/AddRGBPoint).
static void BKInsertPoint(NSMutableData *points, BKTFPoint point)
{
    NSUInteger count = points.length / sizeof(BKTFPoint);
    BKTFPoint *p = points.mutableBytes;
    NSUInteger i = 0;
    while (i < count && p[i].value < point.value) i++;
    if (i < count && p[i].value == point.value) {
        p[i] = point;
        return;
    }
    [points replaceBytesInRange:NSMakeRange(i * sizeof(BKTFPoint), 0) withBytes:&point length:sizeof(BKTFPoint)];
}

- (void)addColorPointAtValue:(float)value red:(float)red green:(float)green blue:(float)blue
{
    BKInsertPoint(_colorPoints, (BKTFPoint){value, {red, green, blue}});
}

- (void)addOpacityPointAtValue:(float)value opacity:(float)opacity
{
    BKInsertPoint(_opacityPoints, (BKTFPoint){value, {opacity, 0, 0}});
}

- (void)removeAllPoints
{
    _colorPoints.length = 0;
    _opacityPoints.length = 0;
}

// The maths lives in the plain-C core (BKRenderCore.c); these methods only hand over
// the point lists.

// Smallest value used by any point (0 when there are no points at all).
- (float)minimumValue
{
    return BKRenderTFMinimumValue(_colorPoints.bytes, self.colorPointCount, _opacityPoints.bytes, self.opacityPointCount);
}

// Largest value used by any point (0 when there are no points at all).
- (float)maximumValue
{
    return BKRenderTFMaximumValue(_colorPoints.bytes, self.colorPointCount, _opacityPoints.bytes, self.opacityPointCount);
}

- (void)getRGBA:(float[4])rgba atValue:(float)value
{
    BKRenderTFGetRGBA(_colorPoints.bytes, self.colorPointCount, _opacityPoints.bytes, self.opacityPointCount, value, rgba);
}

- (void)bakeIntoRGBA:(float *)rgba count:(NSUInteger)count
{
    BKRenderTFBake(_colorPoints.bytes, self.colorPointCount, _opacityPoints.bytes, self.opacityPointCount, rgba, count);
}

+ (instancetype)grayscaleRampFromValue:(float)low toValue:(float)high
{
    BKTransferFunction *tf = [[self alloc] init];
    [tf addColorPointAtValue:low red:0 green:0 blue:0];
    [tf addColorPointAtValue:high red:1 green:1 blue:1];
    [tf addOpacityPointAtValue:low opacity:0];
    [tf addOpacityPointAtValue:high opacity:1];
    return tf;
}

+ (instancetype)transferFunctionWithCLUTRed:(const uint8_t *)red green:(const uint8_t *)green blue:(const uint8_t *)blue
                               windowCenter:(float)windowCenter windowWidth:(float)windowWidth
                              opacityPoints:(const CGPoint *)opacityPoints count:(NSUInteger)count
{
    // 2026-11-26 (Vulkan plan 7.1 #4a): the VRView rules live in the plain-C core BKRenderTFFromCLUT (same arithmetic
    // as the code that was here, shared with the Vulkan engine); this method only hands over and takes back the points.
    BKTransferFunction *tf = [[self alloc] init];
    double *xy = count ? malloc(2 * count * sizeof(double)) : NULL;
    BKTFPoint *opacity = malloc((count + 2) * sizeof(BKTFPoint));
    BKTFPoint color[255];
    for (NSUInteger i = 0; i < count; i++) { xy[2 * i] = opacityPoints[i].x; xy[2 * i + 1] = opacityPoints[i].y; }
    size_t colorCount = 0, opacityCount = 0;
    BKRenderTFFromCLUT(red, green, blue, windowCenter, windowWidth, xy, count, color, &colorCount, opacity, &opacityCount);
    [tf->_colorPoints appendBytes:color length:colorCount * sizeof(BKTFPoint)];
    [tf->_opacityPoints appendBytes:opacity length:opacityCount * sizeof(BKTFPoint)];
    free(xy);
    free(opacity);
    return tf;
}

@end
