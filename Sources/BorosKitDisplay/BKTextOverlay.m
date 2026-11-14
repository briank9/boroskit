// BorosKitDisplay: BKTextOverlay - see include/BKTextOverlay.h.
// Original BorosKit code written for this project; contains no third-party code.
// Apple drawing layer: measuring with Core Text, placement from BKTextLayoutCore (plain C),
// drawing through BKOverlayText so labels look exactly like the other BorosKit overlay text.

#import "BKTextOverlay.h"
#import <CoreText/CoreText.h>

// What: the font BKOverlayText draws with (system UI font, bold = emphasized), caller releases.
static CTFontRef BKTextOverlayCreateFont(CGFloat fontSize, BOOL bold)
{
    CTFontRef font = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, fontSize, NULL);
    if (font == NULL) font = CTFontCreateWithName(bold ? CFSTR("Helvetica-Bold") : CFSTR("Helvetica"), fontSize, NULL);
    return font;
}

CGFloat BKTextOverlayLineHeight(CGFloat fontSize, BOOL bold)
{
    CTFontRef font = BKTextOverlayCreateFont(fontSize, bold);
    if (font == NULL) return fontSize * 1.2;
    CGFloat h = CTFontGetAscent(font) + CTFontGetDescent(font);
    CFRelease(font);
    return h;
}

CGFloat BKTextOverlayLineWidth(NSString *line, CGFloat fontSize, BOOL bold)
{
    if (line.length == 0) return 0;
    CTFontRef font = BKTextOverlayCreateFont(fontSize, bold);
    if (font == NULL) return 0;
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:line
                                                            attributes:@{ (__bridge id)kCTFontAttributeName: (__bridge id)font }];
    CTLineRef ct = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGFloat w = ct ? (CGFloat)CTLineGetTypographicBounds(ct, NULL, NULL, NULL) : 0;
    if (ct) CFRelease(ct);
    CFRelease(font);
    return w;
}

@implementation BKTextOverlayItem

- (instancetype)init
{
    if ((self = [super init])) {
        _fontSize = 12;
        _lineSpacing = 1.1;   // VTK text default, kept so multi-line labels stack as before
        _color = BKColorMake(1, 1, 1, 1);
        _horizontalAlignment = BKTextAlignLeft;
        _verticalAlignment = BKTextAlignTop;
    }
    return self;
}

+ (instancetype)itemWithText:(NSString *)text corner:(int32_t)corner
{
    BKTextOverlayItem *item = [[self alloc] init];
    item.text = text;
    BKVec2f a;
    int32_t h, v;
    BKTextLayoutCornerAnchor(corner, &a, &h, &v);
    item.anchor = CGPointMake(a.x, a.y);
    item.horizontalAlignment = (BKTextHorizontalAlignment)h;
    item.verticalAlignment = v == BKTextLayoutTop ? BKTextAlignTop : (v == BKTextLayoutMiddle ? BKTextAlignMiddle : BKTextAlignBottom);
    return item;
}

+ (instancetype)itemWithText:(NSString *)text anchor:(CGPoint)anchor
{
    BKTextOverlayItem *item = [[self alloc] init];
    item.text = text;
    item.anchor = anchor;
    return item;
}

- (id)copyWithZone:(NSZone *)zone
{
    BKTextOverlayItem *c = [[[self class] allocWithZone:zone] init];
    c.text = _text; c.anchor = _anchor; c.offset = _offset;
    c.horizontalAlignment = _horizontalAlignment; c.verticalAlignment = _verticalAlignment;
    c.fontSize = _fontSize; c.lineSpacing = _lineSpacing; c.color = _color;
    c.bold = _bold; c.shadow = _shadow; c.hidden = _hidden; c.identifier = _identifier;
    return c;
}

- (BKTextLayoutItem)layoutItemWithLineHeight:(CGFloat)lineHeight
{
    BKTextLayoutItem l;
    l.anchor = BKV2f((float)_anchor.x, (float)_anchor.y);
    l.offset = BKV2f((float)_offset.x, (float)_offset.y);
    l.horizontal = _horizontalAlignment == BKTextAlignCenter ? BKTextLayoutCenter
                 : (_horizontalAlignment == BKTextAlignRight ? BKTextLayoutRight : BKTextLayoutLeft);
    l.vertical = _verticalAlignment == BKTextAlignTop ? BKTextLayoutTop
               : (_verticalAlignment == BKTextAlignMiddle ? BKTextLayoutMiddle : BKTextLayoutBottom);
    l.lineHeight = (float)lineHeight;
    l.lineSpacing = (float)_lineSpacing;
    return l;
}

@end

@implementation BKTextOverlay

- (instancetype)init
{
    if ((self = [super init])) _items = @[];
    return self;
}

- (BKTextOverlayItem *)itemWithIdentifier:(NSString *)identifier
{
    for (BKTextOverlayItem *item in _items)
        if ([item.identifier isEqualToString:identifier]) return item;
    return nil;
}

// What: each line's top-left corner (view points) and the lines themselves.
- (NSArray<NSValue *> *)lineFramesForItem:(BKTextOverlayItem *)item viewSize:(CGSize)viewSize lines:(NSArray<NSString *> **)outLines
{
    NSArray<NSString *> *lines = item.text.length ? [item.text componentsSeparatedByString:@"\n"] : @[];
    if (outLines) *outLines = lines;
    if (lines.count == 0) return @[];
    uint32_t n = (uint32_t)lines.count;
    float *widths = malloc(n * sizeof(float));
    BKVec2f *tops = malloc(n * sizeof(BKVec2f));
    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithCapacity:n];
    if (widths && tops) {
        CGFloat lineHeight = BKTextOverlayLineHeight(item.fontSize, item.bold);
        for (uint32_t i = 0; i < n; i++) widths[i] = (float)BKTextOverlayLineWidth(lines[i], item.fontSize, item.bold);
        BKTextLayoutItem layout = [item layoutItemWithLineHeight:lineHeight];
        BKTextLayoutLines(&layout, (float)viewSize.width, (float)viewSize.height, widths, n, tops);
        for (uint32_t i = 0; i < n; i++)
            [frames addObject:[NSValue valueWithBytes:&(CGRect){ { tops[i].x, tops[i].y }, { widths[i], lineHeight } } objCType:@encode(CGRect)]];
    }
    free(widths);
    free(tops);
    return frames;
}

- (NSArray<NSValue *> *)lineFramesForItem:(BKTextOverlayItem *)item viewSize:(CGSize)viewSize
{
    return [self lineFramesForItem:item viewSize:viewSize lines:NULL];
}

- (void)drawInContext:(CGContextRef)context viewSize:(CGSize)viewSize
{
    if (context == NULL || viewSize.width <= 0 || viewSize.height <= 0) return;
    NSMutableArray<BKOverlayItem *> *drawn = [NSMutableArray array];
    for (BKTextOverlayItem *item in _items) {
        if (item.hidden || item.text.length == 0) continue;
        NSArray<NSString *> *lines = nil;
        NSArray<NSValue *> *frames = [self lineFramesForItem:item viewSize:viewSize lines:&lines];
        for (NSUInteger i = 0; i < frames.count; i++) {
            if (lines[i].length == 0) continue;
            CGRect r;
            [frames[i] getValue:&r];
            // Left-aligned at the line's own top-left: the core already applied the alignment.
            BKOverlayText *t = [BKOverlayText text:lines[i] at:r.origin];
            t.offset = CGPointZero;
            t.fontSize = item.fontSize;
            t.strokeColor = item.color;
            t.bold = item.bold;
            t.shadow = item.shadow;
            t.horizontalAlignment = BKTextAlignLeft;
            t.verticalAlignment = BKTextAlignTop;
            [drawn addObject:t];
        }
    }
    if (drawn.count == 0) return;
    // 1:1 transform: overlay "image pixels" = view points.
    BKDrawOverlays(context, drawn, BKViewTransformMakeFit(viewSize.width, viewSize.height, viewSize.width, viewSize.height));
}

@end
