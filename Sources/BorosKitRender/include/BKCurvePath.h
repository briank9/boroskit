// BorosKitRender: BKCurvePath - the path object of the curved MPR (Objective-C wrapper over the plain-C
// BKCurveCore). Replaces Horos' N3BezierPath in Boros 6's curved-MPR window (2026-11-15).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends):
// - VULKAN: safe to translate directly - this is thin Apple glue (an NSObject holding a list of
//   move / line / cubic-curve elements); every computation is in BKCurveCore.c (C99, BKVec), which a
//   Windows/Linux build calls directly. A C++ port is a std::vector of the same element struct.
// - No Horos-derived (LGPL) types: points are BKVec3d, transforms are BKCurveTransform (own struct,
//   same layout as Core Animation's CATransform3D so the app can convert its matrices field by field).
//
// Plain language: a path is a list of "go to this point", "draw a straight line to this point" and
// "draw a smooth curve to this point" steps. The curved-MPR curve is one such path (made through the
// user's nodes); the views also use paths to draw lines on the pictures. Every measurement (length,
// point at 40% of the way, closest point to the mouse, ...) is made on one fine straight-line version
// of the curves (pieces within 0.1 mm), the same one the panorex generator samples - so the picture
// and the lines always agree.

#import <Foundation/Foundation.h>
#import "BKVec.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKCurvePathElement) {
    BKCurvePathMoveTo = 0,
    BKCurvePathLineTo = 1,
    BKCurvePathCurveTo = 2,
};

// What: an affine transform with the CATransform3D layout and row-vector convention:
// x' = x*m11 + y*m21 + z*m31 + m41 (and so on); m14, m24, m34 = 0, m44 = 1.
typedef struct {
    double m11, m12, m13, m14;
    double m21, m22, m23, m24;
    double m31, m32, m33, m34;
    double m41, m42, m43, m44;
} BKCurveTransform;

BKVec3d BKCurveTransformPoint(BKCurveTransform t, BKVec3d p);

@interface BKCurvePath : NSObject <NSCopying, NSSecureCoding>

// What: the smooth curve through `count` nodes (BKCurveSegmentsFromNodes); an empty path for fewer than
// 2 nodes or unusable nodes.
+ (instancetype)pathThroughNodes:(const BKVec3d *)nodes count:(NSUInteger)count;
// What: the closed outline through the nodes (BKCurveSegmentsFromNodesClosed); 2 nodes give the straight
// piece between them (as the classic engine did), fewer an empty path.
+ (instancetype)closedPathThroughNodes:(const BKVec3d *)nodes count:(NSUInteger)count;

// --- building ---------------------------------------------------------------------------------
- (void)moveTo:(BKVec3d)point;
- (void)lineTo:(BKVec3d)point;
- (void)curveTo:(BKVec3d)endpoint control1:(BKVec3d)control1 control2:(BKVec3d)control2;
// What: a straight line back to the start of the current subpath (stored as a line element).
- (void)close;
// What: replaces the points of element `index` (its type stays the same); out-of-range is ignored.
- (void)setElementAtIndex:(NSUInteger)index control1:(BKVec3d)control1 control2:(BKVec3d)control2 endpoint:(BKVec3d)endpoint;

// --- reading ----------------------------------------------------------------------------------
@property (nonatomic, readonly) NSUInteger elementCount;
@property (nonatomic, readonly) NSUInteger subpathCount;   // number of moveTo elements
- (BKCurvePathElement)elementAtIndex:(NSUInteger)index control1:(nullable BKVec3d *)control1
                            control2:(nullable BKVec3d *)control2 endpoint:(nullable BKVec3d *)endpoint;
- (BOOL)isEqualToPath:(BKCurvePath *)other;

// --- measuring (single-subpath paths; on the fine polyline: pieces within 0.1 mm, split at 3 mm) ----
@property (nonatomic, readonly) double length;
- (double)lengthThroughElementAtIndex:(NSUInteger)index;   // length up to the end of that element
- (BKVec3d)vectorAtRelativePosition:(double)relativePosition;   // relativePosition 0..1 of the length
- (BKVec3d)tangentAtRelativePosition:(double)relativePosition;
- (BKVec3d)normalAtRelativePosition:(double)relativePosition initialNormal:(BKVec3d)initialNormal;
@property (nonatomic, readonly) BKVec3d vectorAtStart, vectorAtEnd, tangentAtStart, tangentAtEnd;
- (double)relativePositionClosestToVector:(BKVec3d)vector closestVector:(nullable BKVec3d *)closest;
- (double)relativePositionClosestToLinePoint:(BKVec3d)linePoint direction:(BKVec3d)direction
                               closestVector:(nullable BKVec3d *)closest;

// What: samples every `spacing` mm (BKCurvePolylineSample); outputs may be NULL; returns the count.
- (NSUInteger)sampleWithSpacing:(double)spacing startDistance:(double)startDistance initialNormal:(BKVec3d)initialNormal
                      positions:(nullable BKVec3d *)positions tangents:(nullable BKVec3d *)tangents
                        normals:(nullable BKVec3d *)normals maxSamples:(NSUInteger)maxSamples;
// What: stretched sampling (BKCurvePolylineSampleProjected) and the length it is spaced along.
- (NSUInteger)sampleProjectedWithSpacing:(double)spacing startDistance:(double)startDistance
                     projectionDirection:(BKVec3d)direction positions:(nullable BKVec3d *)positions
                                tangents:(nullable BKVec3d *)tangents normals:(nullable BKVec3d *)normals
                       relativePositions:(nullable double *)relativePositions maxSamples:(NSUInteger)maxSamples;
- (double)projectedLengthAlongDirection:(BKVec3d)direction;

// What: where the path crosses the plane (BKCurvePolylinePlaneIntersections), in order: NSValues of
// BKVec3d ("{BKVec3d=ddd}" encoded) and, optionally, NSNumbers of the relative positions.
- (NSArray<NSValue *> *)intersectionsWithPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
                                  relativePositions:(NSArray<NSNumber *> * _Nullable * _Nullable)relativePositions;

// --- planes -----------------------------------------------------------------------------------
@property (nonatomic, readonly) BOOL isPlanar;   // all points within 1e-4 mm of one plane
- (BOOL)getLeastSquaresPlanePoint:(BKVec3d *)point normal:(BKVec3d *)normal;
- (BKVec3d)topBoundingPointForNormal:(BKVec3d)normal;     // the plane perpendicular to normal through this point
- (BKVec3d)bottomBoundingPointForNormal:(BKVec3d)normal;  //   touches the path on its +normal / -normal side

// --- changing (in place) ----------------------------------------------------------------------
- (void)subdivide:(double)maxSegmentLength;   // splits curve elements longer than this (control polygon)
- (void)flatten:(double)flatness;             // curve elements -> line elements within `flatness`
- (void)applyTransform:(BKCurveTransform)transform;
- (void)projectToPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal;
// What: flattens (default flatness) and adds a point wherever a line crosses the plane.
- (void)addEndpointsAtIntersectionsWithPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal;

// --- new paths ----------------------------------------------------------------------------------
- (BKCurvePath *)pathByFlattening:(double)flatness;
- (BKCurvePath *)pathByProjectingToPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal;
// What: the two side lines `distance` mm either side of the curve (two subpaths: +side, -side), points
// every `spacing` mm plus the end; across = the transported normal (initialNormal) or
// unit(projectionNormal x tangent). nil when the path is not one subpath or shorter than 2 * spacing.
- (nullable BKCurvePath *)outlinePathAtDistance:(double)distance initialNormal:(BKVec3d)initialNormal spacing:(double)spacing;
- (nullable BKCurvePath *)outlinePathAtDistance:(double)distance projectionNormal:(BKVec3d)projectionNormal spacing:(double)spacing;

@end

NS_ASSUME_NONNULL_END
