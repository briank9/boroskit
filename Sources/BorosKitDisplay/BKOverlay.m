// BorosKitDisplay: overlay items and CoreGraphics drawing. See BKOverlay.h.

#import "BKOverlay.h"
#import "N3BezierPath.h"
#import <CoreText/CoreText.h>
#import <math.h>

// What: sets a CoreGraphics stroke colour from a BKColor. Why: BKColor is platform-neutral
// (no NSColor/UIColor), and device RGB keeps colours identical on Mac and iPad.
static void BKSetStroke(CGContextRef ctx, BKColor c)
{
    CGContextSetRGBStrokeColor(ctx, c.red, c.green, c.blue, c.alpha);
}

// What: same for fill colour.
static void BKSetFill(CGContextRef ctx, BKColor c)
{
    CGContextSetRGBFillColor(ctx, c.red, c.green, c.blue, c.alpha);
}

// What: distance from p to segment ab (all in view points).
// Why: hit-testing lines, polylines and flattened curves.
static CGFloat BKDistanceToSegment(CGPoint p, CGPoint a, CGPoint b)
{
    CGFloat dx = b.x - a.x, dy = b.y - a.y;
    CGFloat len2 = dx * dx + dy * dy;
    CGFloat t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0;
    t = fmax(0, fmin(1, t));
    CGFloat qx = a.x + t * dx - p.x, qy = a.y + t * dy - p.y;
    return sqrt(qx * qx + qy * qy);
}

#pragma mark - Base

@implementation BKOverlayItem

// What: default style (yellow 1.5 pt lines, no fill), like Horos' default ROI colour.
- (instancetype)init
{
    if ((self = [super init])) {
        _strokeColor = BKColorMake(1, 1, 0, 1);
        _fillColor = BKColorMake(0, 0, 0, 0);
        _lineWidth = 1.5;
    }
    return self;
}

// What: applies stroke colour, width and dash pattern. Why: every subclass strokes the
// same way; widths are in view points so lines stay thin when zoomed in.
- (void)applyStrokeStyleInContext:(CGContextRef)ctx
{
    BKSetStroke(ctx, _strokeColor);
    CGContextSetLineWidth(ctx, _lineWidth);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    if (_dashed) {
        CGFloat pattern[2] = { 6, 4 };
        CGContextSetLineDash(ctx, 0, pattern, 2);
    } else {
        CGContextSetLineDash(ctx, 0, NULL, 0);
    }
}

// What: fills (if a fill colour is set) and strokes a path that is ALREADY in view points.
// Why: geometry is transformed first and stroked afterwards, so the zoom never scales the
// line width (stroking inside a scaled CTM would make lines fat when zoomed in).
- (void)fillAndStrokeViewPath:(CGPathRef)path inContext:(CGContextRef)ctx
{
    if (_fillColor.alpha > 0) {
        BKSetFill(ctx, _fillColor);
        CGContextAddPath(ctx, path);
        CGContextFillPath(ctx);
    }
    [self applyStrokeStyleInContext:ctx];
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
}

// What: subclasses draw themselves; the base draws nothing.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
}

// What: subclasses measure their own distance; the base is never "near".
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    return CGFLOAT_MAX;
}

@end

#pragma mark - Line

@implementation BKOverlayLine

// What: convenience constructor in image pixels.
+ (instancetype)lineFrom:(CGPoint)start to:(CGPoint)end
{
    BKOverlayLine *line = [[self alloc] init];
    line.start = start;
    line.end = end;
    return line;
}

// What: maps both ends to the view and strokes the segment.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    CGPoint a = BKViewTransformImagePointToView(transform, _start);
    CGPoint b = BKViewTransformImagePointToView(transform, _end);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, a.x, a.y);
    CGPathAddLineToPoint(path, NULL, b.x, b.y);
    [self fillAndStrokeViewPath:path inContext:context];
    CGPathRelease(path);
}

// What: on-screen distance to the segment, for selecting a measurement by clicking it.
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    return BKDistanceToSegment(viewPoint, BKViewTransformImagePointToView(transform, _start),
                               BKViewTransformImagePointToView(transform, _end));
}

@end

#pragma mark - Polyline

@implementation BKOverlayPolyline {
    NSData *_points; // CGPoint array, image pixels
}

// What: copies the points. Why: callers often pass a temporary C array.
+ (instancetype)polylineWithPoints:(const CGPoint *)points count:(NSUInteger)count closed:(BOOL)closed
{
    BKOverlayPolyline *poly = [[self alloc] init];
    poly->_points = [NSData dataWithBytes:points length:sizeof(CGPoint) * count];
    poly.closed = closed;
    return poly;
}

// What: number of vertices.
- (NSUInteger)pointCount
{
    return _points.length / sizeof(CGPoint);
}

// What: one vertex in image pixels.
- (CGPoint)pointAtIndex:(NSUInteger)index
{
    NSParameterAssert(index < self.pointCount);
    return ((const CGPoint *)_points.bytes)[index];
}

// What: builds the path in view points (closing it for polygons) and draws it.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    NSUInteger n = self.pointCount;
    if (n < 2)
        return;
    CGAffineTransform m = BKViewTransformImageToView(transform);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, &m, (const CGPoint *)_points.bytes, n);
    if (_closed)
        CGPathCloseSubpath(path);
    [self fillAndStrokeViewPath:path inContext:context];
    CGPathRelease(path);
}

// What: nearest distance to any edge (including the closing edge of polygons).
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    NSUInteger n = self.pointCount;
    if (n == 0)
        return CGFLOAT_MAX;
    const CGPoint *pts = _points.bytes;
    CGFloat best = CGFLOAT_MAX;
    CGPoint prev = BKViewTransformImagePointToView(transform, pts[0]);
    if (n == 1)
        return hypot(viewPoint.x - prev.x, viewPoint.y - prev.y);
    CGPoint first = prev;
    for (NSUInteger i = 1; i < n; i++) {
        CGPoint cur = BKViewTransformImagePointToView(transform, pts[i]);
        best = fmin(best, BKDistanceToSegment(viewPoint, prev, cur));
        prev = cur;
    }
    if (_closed)
        best = fmin(best, BKDistanceToSegment(viewPoint, prev, first));
    return best;
}

@end

#pragma mark - Curve

// What: CGPathApply callback that accumulates the minimum distance to the (flattened)
// path's segments. Why: CGPath has no built-in "distance to point".
typedef struct {
    CGPoint point;
    CGPoint current;
    CGPoint subpathStart;
    CGFloat best;
} BKPathDistanceState;

// What: approximates cubic/quadratic segments with short lines for hit-testing.
// Why: exact curve distance is unnecessary for a click tolerance of a few points.
static void BKPathDistanceApplier(void *info, const CGPathElement *element)
{
    BKPathDistanceState *s = info;
    const CGPoint *p = element->points;
    switch (element->type) {
        case kCGPathElementMoveToPoint:
            s->current = s->subpathStart = p[0];
            break;
        case kCGPathElementAddLineToPoint:
            s->best = fmin(s->best, BKDistanceToSegment(s->point, s->current, p[0]));
            s->current = p[0];
            break;
        case kCGPathElementAddQuadCurveToPoint:
        case kCGPathElementAddCurveToPoint: {
            BOOL cubic = element->type == kCGPathElementAddCurveToPoint;
            CGPoint p0 = s->current, c1 = p[0], c2 = cubic ? p[1] : p[0], p3 = cubic ? p[2] : p[1];
            CGPoint prev = p0;
            for (int i = 1; i <= 16; i++) {
                CGFloat t = i / 16.0, u = 1 - t;
                CGPoint q;
                if (cubic) {
                    q.x = u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p3.x;
                    q.y = u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p3.y;
                } else {
                    q.x = u*u*p0.x + 2*u*t*c1.x + t*t*p3.x;
                    q.y = u*u*p0.y + 2*u*t*c1.y + t*t*p3.y;
                }
                s->best = fmin(s->best, BKDistanceToSegment(s->point, prev, q));
                prev = q;
            }
            s->current = p3;
            break;
        }
        case kCGPathElementCloseSubpath:
            s->best = fmin(s->best, BKDistanceToSegment(s->point, s->current, s->subpathStart));
            s->current = s->subpathStart;
            break;
    }
}

@implementation BKOverlayCurve {
    CGPathRef _imagePath;
}

// What: stores a copy of a CGPath given in image pixels.
+ (instancetype)curveWithImagePath:(CGPathRef)path
{
    BKOverlayCurve *curve = [[self alloc] init];
    curve->_imagePath = CGPathCreateCopy(path);
    return curve;
}

// What: converts the CPR engine's N3BezierPath (patient mm) into an image-pixel CGPath,
// keeping Bezier segments as curves. Why: the panorex curve and curved ROIs live in
// patient space in BorosKitCore; the display needs them in this image's pixels.
+ (instancetype)curveWithBezierPath:(N3BezierPath *)bezierPath patientToImage:(N3AffineTransform)patientToImage
{
    CGMutablePathRef path = CGPathCreateMutable();
    NSInteger count = [bezierPath elementCount];
    for (NSInteger i = 0; i < count; i++) {
        N3Vector c1, c2, end;
        N3BezierPathElement type = [bezierPath elementAtIndex:i control1:&c1 control2:&c2 endpoint:&end];
        N3Vector e = N3VectorApplyTransform(end, patientToImage);
        switch (type) {
            case N3MoveToBezierPathElement:
                CGPathMoveToPoint(path, NULL, e.x, e.y);
                break;
            case N3LineToBezierPathElement:
                CGPathAddLineToPoint(path, NULL, e.x, e.y);
                break;
            case N3CurveToBezierPathElement: {
                N3Vector a = N3VectorApplyTransform(c1, patientToImage);
                N3Vector b = N3VectorApplyTransform(c2, patientToImage);
                CGPathAddCurveToPoint(path, NULL, a.x, a.y, b.x, b.y, e.x, e.y);
                break;
            }
            case N3CloseBezierPathElement:
                CGPathCloseSubpath(path);
                break;
            default:
                break;
        }
    }
    BKOverlayCurve *curve = [self curveWithImagePath:path];
    CGPathRelease(path);
    return curve;
}

// What: releases the owned CGPath (ARC does not manage CoreFoundation objects).
- (void)dealloc
{
    if (_imagePath)
        CGPathRelease(_imagePath);
}

- (CGPathRef)imagePath
{
    return _imagePath;
}

// What: transforms the whole path to view points (curves stay curves) and strokes it.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    if (!_imagePath)
        return;
    CGAffineTransform m = BKViewTransformImageToView(transform);
    CGPathRef viewPath = CGPathCreateCopyByTransformingPath(_imagePath, &m);
    [self fillAndStrokeViewPath:viewPath inContext:context];
    CGPathRelease(viewPath);
}

// What: approximate on-screen distance to the curve.
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    if (!_imagePath)
        return CGFLOAT_MAX;
    CGAffineTransform m = BKViewTransformImageToView(transform);
    CGPathRef viewPath = CGPathCreateCopyByTransformingPath(_imagePath, &m);
    BKPathDistanceState state = { viewPoint, CGPointZero, CGPointZero, CGFLOAT_MAX };
    CGPathApply(viewPath, &state, BKPathDistanceApplier);
    CGPathRelease(viewPath);
    return state.best;
}

@end

#pragma mark - Point

@implementation BKOverlayPoint

// What: convenience constructor; handles default to a 4-point filled dot.
+ (instancetype)pointAt:(CGPoint)position
{
    BKOverlayPoint *p = [[self alloc] init];
    p.position = position;
    p.radius = 4;
    p.filled = YES;
    return p;
}

// What: draws a dot of fixed on-screen size at the transformed position.
// Why: handles must stay grabbable at any zoom, so their size is not scaled.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    CGPoint c = BKViewTransformImagePointToView(transform, _position);
    CGRect r = CGRectMake(c.x - _radius, c.y - _radius, 2 * _radius, 2 * _radius);
    if (_filled) {
        BKSetFill(context, self.strokeColor);
        CGContextFillEllipseInRect(context, r);
    } else {
        [self applyStrokeStyleInContext:context];
        CGContextStrokeEllipseInRect(context, r);
    }
}

// What: distance to the dot's edge (0 inside it).
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    CGPoint c = BKViewTransformImagePointToView(transform, _position);
    return fmax(0, hypot(viewPoint.x - c.x, viewPoint.y - c.y) - _radius);
}

@end

#pragma mark - Rect / ellipse

@implementation BKOverlayRect

// What: convenience constructor (image pixels).
+ (instancetype)rectWithImageRect:(CGRect)rect ellipse:(BOOL)ellipse
{
    BKOverlayRect *r = [[self alloc] init];
    r.imageRect = rect;
    r.ellipse = ellipse;
    return r;
}

// What: builds the outline in image space and transforms it.
// Why: under rotation or non-square pixels a rectangle becomes a rotated/stretched shape
// on screen, which a transformed path handles exactly.
- (CGPathRef)newViewPathForTransform:(BKViewTransform)transform CF_RETURNS_RETAINED
{
    CGAffineTransform m = BKViewTransformImageToView(transform);
    return _ellipse ? CGPathCreateWithEllipseInRect(_imageRect, &m) : CGPathCreateWithRect(_imageRect, &m);
}

// What: draws the transformed outline (and optional fill).
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    CGPathRef path = [self newViewPathForTransform:transform];
    [self fillAndStrokeViewPath:path inContext:context];
    CGPathRelease(path);
}

// What: on-screen distance to the outline.
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    CGPathRef path = [self newViewPathForTransform:transform];
    BKPathDistanceState state = { viewPoint, CGPointZero, CGPointZero, CGFLOAT_MAX };
    CGPathApply(path, &state, BKPathDistanceApplier);
    CGPathRelease(path);
    return state.best;
}

@end

#pragma mark - Text

// What: draws one line of text with its baseline-left corner at (x, y) in a y-down context.
// Why: CoreText assumes y-up; flipping the text matrix makes glyphs upright in our
// top-left-origin view space, on both Mac and iPad. Returns the drawn size.
static CGSize BKDrawText(CGContextRef ctx, NSString *text, CGFloat fontSize, BKColor color,
                         CGFloat x, CGFloat y, BOOL background)
{
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, fontSize, NULL);
    if (!font)
        font = CTFontCreateWithName(CFSTR("Helvetica"), fontSize, NULL);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[4] = { color.red, color.green, color.blue, color.alpha };
    CGColorRef cgColor = CGColorCreate(space, comps);
    NSDictionary *attrs = @{ (__bridge id)kCTFontAttributeName: (__bridge id)font,
                             (__bridge id)kCTForegroundColorAttributeName: (__bridge id)cgColor };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);

    if (background) {
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 0.6);
        CGContextFillRect(ctx, CGRectMake(x - 2, y - ascent - 2, width + 4, ascent + descent + 4));
    }
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
    CGContextSetTextPosition(ctx, x, y);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);

    CFRelease(line);
    CGColorRelease(cgColor);
    CGColorSpaceRelease(space);
    CFRelease(font);
    return CGSizeMake(width, ascent + descent);
}

@implementation BKOverlayText

// What: convenience constructor; default 12 pt, offset slightly up-right of the anchor.
+ (instancetype)text:(NSString *)text at:(CGPoint)anchor
{
    BKOverlayText *t = [[self alloc] init];
    t.text = text;
    t.anchor = anchor;
    t.fontSize = 12;
    t.offset = CGPointMake(6, -6);
    return t;
}

// What: draws the label upright and fixed-size next to its transformed anchor.
// Why: labels (ROI names, measurement values) must stay readable regardless of zoom
// and rotation, as in Horos.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    if (_text.length == 0)
        return;
    CGPoint p = BKViewTransformImagePointToView(transform, _anchor);
    BKDrawText(context, _text, _fontSize, self.strokeColor, p.x + _offset.x, p.y + _offset.y, _drawsBackground);
}

// What: distance to the anchor point (labels are selected via their anchor).
- (CGFloat)distanceFromViewPoint:(CGPoint)viewPoint transform:(BKViewTransform)transform
{
    CGPoint p = BKViewTransformImagePointToView(transform, _anchor);
    return hypot(viewPoint.x - p.x, viewPoint.y - p.y);
}

@end

#pragma mark - Scale bar

@implementation BKOverlayScaleBar

// What: default bar in the bottom-left corner, about 100 points long.
+ (instancetype)scaleBar
{
    BKOverlayScaleBar *bar = [[self alloc] init];
    bar.margin = 16;
    bar.targetLength = 100;
    bar.strokeColor = BKColorMake(0, 1, 0, 1); // Horos draws its ruler in green
    return bar;
}

// What: picks a "round" length (1, 2 or 5 x 10^n mm) whose on-screen size is closest to
// targetLength. Why: a bar labelled "10 mm" is easier to read than "13.7 mm".
- (CGFloat)lengthInMillimetresForTransform:(BKViewTransform)transform
{
    CGFloat mmPerPoint = BKViewTransformMillimetresPerViewPoint(transform);
    if (!(mmPerPoint > 0))
        return 0;
    CGFloat ideal = _targetLength * mmPerPoint;
    CGFloat exponent = floor(log10(ideal));
    CGFloat base = pow(10, exponent);
    CGFloat best = base, bestErr = CGFLOAT_MAX;
    for (int i = 0; i < 4; i++) {
        CGFloat candidates[4] = { 1, 2, 5, 10 };
        CGFloat len = candidates[i] * base;
        CGFloat err = fabs(log(len / ideal));
        if (err < bestErr) { bestErr = err; best = len; }
    }
    return best;
}

// What: draws the bar with end ticks and a label in the bottom-left of the view.
// Why: the old OpenGL ruler in DCMView; view-anchored, so it never scrolls away.
- (void)drawInContext:(CGContextRef)context transform:(BKViewTransform)transform
{
    CGFloat mm = [self lengthInMillimetresForTransform:transform];
    CGFloat mmPerPoint = BKViewTransformMillimetresPerViewPoint(transform);
    if (!(mm > 0) || !(mmPerPoint > 0))
        return;
    CGFloat length = mm / mmPerPoint;
    CGFloat x0 = _margin, y = transform.viewHeight - _margin;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, x0, y - 5);
    CGPathAddLineToPoint(path, NULL, x0, y);
    CGPathAddLineToPoint(path, NULL, x0 + length, y);
    CGPathAddLineToPoint(path, NULL, x0 + length, y - 5);
    [self fillAndStrokeViewPath:path inContext:context];
    CGPathRelease(path);
    NSString *label = mm >= 10 ? [NSString stringWithFormat:@"%.0f cm", mm / 10] : [NSString stringWithFormat:@"%g mm", mm];
    BKDrawText(context, label, 11, self.strokeColor, x0 + length + 6, y, NO);
}

@end

#pragma mark - Drawing / hit-testing

// What: draws all visible items in order. Why: one call for BKImageView and for
// offscreen snapshots (exports with burned-in annotations).
void BKDrawOverlays(CGContextRef context, NSArray<BKOverlayItem *> *items, BKViewTransform transform)
{
    for (BKOverlayItem *item in items) {
        if (item.hidden)
            continue;
        CGContextSaveGState(context);
        [item drawInContext:context transform:transform];
        CGContextRestoreGState(context);
    }
}

// What: finds the nearest visible item within tolerance; later (top-most) items win ties.
// Why: clicking/tapping an ROI or handle to select or drag it.
BKOverlayItem *BKOverlayHitTest(NSArray<BKOverlayItem *> *items, CGPoint viewPoint,
                                CGFloat tolerance, BKViewTransform transform)
{
    BKOverlayItem *best = nil;
    CGFloat bestDistance = tolerance;
    for (BKOverlayItem *item in items) {
        if (item.hidden)
            continue;
        CGFloat d = [item distanceFromViewPoint:viewPoint transform:transform];
        if (d <= bestDistance) {
            bestDistance = d;
            best = item;
        }
    }
    return best;
}
