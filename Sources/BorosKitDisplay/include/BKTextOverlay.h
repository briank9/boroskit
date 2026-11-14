// BorosKitDisplay: BKTextOverlay - a list of text labels pinned to spots of a view (WL/WW
// values, orientation letters, angles ...), drawn with CoreGraphics / Core Text.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - The placement rules are plain C in BKTextLayoutCore.h (positions only). This class is the
//   Apple drawing layer: it measures lines with Core Text, asks the core where they go and draws
//   them like BKOverlayText (system font, optional bold, optional black shadow 1 point down-right).
//   Windows/Linux need their own small drawing layer (2D text route still to be chosen,
//   VULKAN-PORT-PLAN R11) on top of the same core.
// - The model (BKTextOverlayItem) is plain data: string, anchor, offset, size, colour, flags.
//
// Plain language: the words written over a 3D picture. Unlike BKOverlayText (which sticks to a
// point of the IMAGE and moves with zoom/pan), these labels stick to the VIEW: "top left, 1 point
// in", "middle of the left edge", "bottom right". Multi-line labels stack their lines.
//
// Drawing contract: the CGContext has view points with the origin at the TOP-LEFT and y down
// (the same contract as BKDrawOverlays).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "BKOverlay.h"            // BKTextHorizontalAlignment / BKTextVerticalAlignment
#import "BKImageLayerRenderer.h" // BKColor
#import "BKTextLayoutCore.h"

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// One label.
@interface BKTextOverlayItem : NSObject <NSCopying>

// What: a label pinned to one of the nine named spots (BKTextCornerTopLeft ... BottomRight):
// anchor and alignments set accordingly, offset 0.
+ (instancetype)itemWithText:(nullable NSString *)text corner:(int32_t)corner;
// What: a label at `anchor` (fractions of the view, (0,0) top-left, y down), left / top aligned.
+ (instancetype)itemWithText:(nullable NSString *)text anchor:(CGPoint)anchor;

@property (nonatomic, copy, nullable) NSString *text;   // "\n" separates lines; nil / "" = nothing drawn
@property (nonatomic) CGPoint anchor;                   // fraction of the view (y down)
@property (nonatomic) CGPoint offset;                   // view points added to the anchor (y down)
@property (nonatomic) BKTextHorizontalAlignment horizontalAlignment;   // each line, default left
// The block of lines at the anchor: BKTextAlignTop / Middle / Bottom (Baseline counts as Bottom).
// Default top.
@property (nonatomic) BKTextVerticalAlignment verticalAlignment;
@property (nonatomic) CGFloat fontSize;                 // view points, default 12
@property (nonatomic) CGFloat lineSpacing;              // line tops apart, in line heights, default 1.1
@property (nonatomic) BKColor color;                    // default white
@property (nonatomic) BOOL bold;                        // default NO
@property (nonatomic) BOOL shadow;                      // default NO
@property (nonatomic) BOOL hidden;                      // default NO
@property (nonatomic, copy, nullable) NSString *identifier;   // free for the app

// The plain-C layout description of this item for a given line height (points).
- (BKTextLayoutItem)layoutItemWithLineHeight:(CGFloat)lineHeight;

@end

@interface BKTextOverlay : NSObject

// The labels, drawn in order (later ones on top).
@property (nonatomic, copy) NSArray<BKTextOverlayItem *> *items;

// First item with this identifier, or nil.
- (nullable BKTextOverlayItem *)itemWithIdentifier:(NSString *)identifier;

// What: draws every visible label into `context` (view points, origin top-left, y down) for a
// view of `viewSize` points.
- (void)drawInContext:(CGContextRef)context viewSize:(CGSize)viewSize;

// What: where each line of `item` goes in a view of `viewSize` (top-left corners, view points),
// with the same fonts as -drawInContext:. For tests / hit areas. Empty lines are included.
- (NSArray<NSValue *> *)lineFramesForItem:(BKTextOverlayItem *)item viewSize:(CGSize)viewSize;

@end

// What: one line's height (ascent + descent) of the font the overlay draws with.
CGFloat BKTextOverlayLineHeight(CGFloat fontSize, BOOL bold);
// What: the drawn width of one line of text in that font.
CGFloat BKTextOverlayLineWidth(NSString *line, CGFloat fontSize, BOOL bold);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
