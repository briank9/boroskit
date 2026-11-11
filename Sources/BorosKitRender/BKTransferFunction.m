// BorosKitRender: BKTransferFunction implementation (see the header for the why).

#import "BKTransferFunction.h"

// One control point: a CT value and up to four components (r,g,b for colour points,
// just [0] = opacity for opacity points).
typedef struct {
    float value;
    float c[3];
} BKTFPoint;

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

// Smallest value used by any point (0 when there are no points at all).
- (float)minimumValue
{
    float m = INFINITY;
    if (self.colorPointCount) m = fminf(m, ((BKTFPoint *)_colorPoints.bytes)[0].value);
    if (self.opacityPointCount) m = fminf(m, ((BKTFPoint *)_opacityPoints.bytes)[0].value);
    return isinf(m) ? 0 : m;
}

// Largest value used by any point (0 when there are no points at all).
- (float)maximumValue
{
    float m = -INFINITY;
    if (self.colorPointCount) m = fmaxf(m, ((BKTFPoint *)_colorPoints.bytes)[self.colorPointCount - 1].value);
    if (self.opacityPointCount) m = fmaxf(m, ((BKTFPoint *)_opacityPoints.bytes)[self.opacityPointCount - 1].value);
    return isinf(m) ? 0 : m;
}

// Piecewise-linear lookup in a sorted point list; clamps to the first/last point
// outside the defined range. Writes `components` floats into out.
static void BKEvaluate(const BKTFPoint *p, NSUInteger count, float value, float *out, int components)
{
    if (count == 0) return;
    if (value <= p[0].value) { for (int k = 0; k < components; k++) out[k] = p[0].c[k]; return; }
    if (value >= p[count - 1].value) { for (int k = 0; k < components; k++) out[k] = p[count - 1].c[k]; return; }
    NSUInteger i = 1;
    while (p[i].value < value) i++;
    float t = (value - p[i - 1].value) / (p[i].value - p[i - 1].value);
    for (int k = 0; k < components; k++) out[k] = p[i - 1].c[k] + t * (p[i].c[k] - p[i - 1].c[k]);
}

- (void)getRGBA:(float[4])rgba atValue:(float)value
{
    rgba[0] = rgba[1] = rgba[2] = rgba[3] = 1.0f;
    BKEvaluate(_colorPoints.bytes, self.colorPointCount, value, rgba, 3);
    BKEvaluate(_opacityPoints.bytes, self.opacityPointCount, value, rgba + 3, 1);
}

- (void)bakeIntoRGBA:(float *)rgba count:(NSUInteger)count
{
    float lo = self.minimumValue, hi = self.maximumValue;
    for (NSUInteger i = 0; i < count; i++) {
        float value = count > 1 ? lo + (hi - lo) * (float)i / (float)(count - 1) : lo;
        [self getRGBA:rgba + 4 * i atValue:value];
    }
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
    BKTransferFunction *tf = [[self alloc] init];
    float start = windowCenter - windowWidth / 2.0f;
    float end = windowCenter + windowWidth / 2.0f;

    // Colour: the 256 table entries are spread evenly over the window, like
    // vtkColorTransferFunction::BuildFunctionFromTable(start, end, 255, table).
    for (int i = 0; i < 256; i++) {
        float value = start + (end - start) * (float)i / 255.0f;
        [tf addColorPointAtValue:value red:red[i] / 255.0f green:green[i] / 255.0f blue:blue[i] / 255.0f];
    }

    // Opacity: same rules as -[VRView setOpacity:].
    if (count == 0 || opacityPoints[0].x != 0)
        [tf addOpacityPointAtValue:start opacity:0];
    for (NSUInteger i = 0; i < count; i++)
        [tf addOpacityPointAtValue:start + (float)(opacityPoints[i].x / 256.0) * (end - start) opacity:(float)opacityPoints[i].y];
    if (count == 0 || opacityPoints[count - 1].x != 256)
        [tf addOpacityPointAtValue:end opacity:1];
    return tf;
}

@end
