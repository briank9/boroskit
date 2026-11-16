// BorosKitRender: BKCurvePath - see include/BKCurvePath.h (what, why, porting notes).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly - Apple glue only; all geometry is in BKCurveCore.c.

#import "BKCurvePath.h"
#import "BKCurveCore.h"

// What: one stored element.
typedef struct {
    int32_t type;                 // BKCurvePathElement
    BKVec3d control1, control2;   // curveTo only
    BKVec3d endpoint;
} BKCurvePathItem;

BKVec3d BKCurveTransformPoint(BKCurveTransform t, BKVec3d p)
{
    return BKV3d(p.x * t.m11 + p.y * t.m21 + p.z * t.m31 + t.m41,
                 p.x * t.m12 + p.y * t.m22 + p.z * t.m32 + t.m42,
                 p.x * t.m13 + p.y * t.m23 + p.z * t.m33 + t.m43);
}

@implementation BKCurvePath {
    NSMutableData *_items;          // BKCurvePathItem[]
    BKCurvePolyline _polyline;      // cached fine polyline (all elements in order), freed on change
    BOOL _polylineValid;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) _items = [NSMutableData data];
    return self;
}

- (void)dealloc
{
    BKCurvePolylineFree(&_polyline);
}

+ (instancetype)closedPathThroughNodes:(const BKVec3d *)nodes count:(NSUInteger)count
{
    // Two nodes: the straight piece between them, as the classic engine drew for any style.
    if (nodes != NULL && count == 2) return [self pathThroughNodes:nodes count:count];
    BKCurvePath *path = [[self alloc] init];
    if (nodes == NULL || count < 3) return path;
    BKCurveSegment *segments = malloc(sizeof(BKCurveSegment) * (count - 1));
    if (segments == NULL) return path;
    size_t n = BKCurveSegmentsFromNodesClosed(nodes, count, segments);
    if (n > 0) {
        [path moveTo:segments[0].p0];
        for (size_t i = 0; i < n; i++) [path curveTo:segments[i].p1 control1:segments[i].c0 control2:segments[i].c1];
    }
    free(segments);
    return path;
}

+ (instancetype)pathThroughNodes:(const BKVec3d *)nodes count:(NSUInteger)count
{
    BKCurvePath *path = [[self alloc] init];
    if (nodes == NULL || count < 2) return path;
    BKCurveSegment *segments = malloc(sizeof(BKCurveSegment) * (count - 1));
    if (segments == NULL) return path;
    size_t n = BKCurveSegmentsFromNodes(nodes, count, segments);
    if (n > 0) {
        [path moveTo:segments[0].p0];
        for (size_t i = 0; i < n; i++) [path curveTo:segments[i].p1 control1:segments[i].c0 control2:segments[i].c1];
    }
    free(segments);
    return path;
}

#pragma mark - Elements

- (const BKCurvePathItem *)items { return (const BKCurvePathItem *)_items.bytes; }
- (NSUInteger)elementCount { return _items.length / sizeof(BKCurvePathItem); }

- (void)changed
{
    BKCurvePolylineFree(&_polyline);
    _polylineValid = NO;
}

- (void)addItem:(BKCurvePathItem)item
{
    [_items appendBytes:&item length:sizeof(item)];
    [self changed];
}

// What: replaces the points of one element (its type stays); out-of-range indices are ignored.
// For a line or move element only the endpoint matters (the controls are stored equal to it).
- (void)setElementAtIndex:(NSUInteger)index control1:(BKVec3d)control1 control2:(BKVec3d)control2 endpoint:(BKVec3d)endpoint
{
    if (index >= self.elementCount) return;
    BKCurvePathItem *it = (BKCurvePathItem *)_items.mutableBytes + index;
    if (it->type == BKCurvePathCurveTo) { it->control1 = control1; it->control2 = control2; }
    else { it->control1 = endpoint; it->control2 = endpoint; }
    it->endpoint = endpoint;
    [self changed];
}

- (void)moveTo:(BKVec3d)p { [self addItem:(BKCurvePathItem){ BKCurvePathMoveTo, p, p, p }]; }
- (void)lineTo:(BKVec3d)p { [self addItem:(BKCurvePathItem){ BKCurvePathLineTo, p, p, p }]; }
- (void)curveTo:(BKVec3d)e control1:(BKVec3d)c1 control2:(BKVec3d)c2 { [self addItem:(BKCurvePathItem){ BKCurvePathCurveTo, c1, c2, e }]; }

- (void)close
{
    const BKCurvePathItem *it = self.items;
    for (NSUInteger i = self.elementCount; i-- > 0;)
        if (it[i].type == BKCurvePathMoveTo) { [self lineTo:it[i].endpoint]; return; }
}

- (NSUInteger)subpathCount
{
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < self.elementCount; i++) if (self.items[i].type == BKCurvePathMoveTo) n++;
    return n;
}

- (BKCurvePathElement)elementAtIndex:(NSUInteger)index control1:(BKVec3d *)control1 control2:(BKVec3d *)control2 endpoint:(BKVec3d *)endpoint
{
    if (index >= self.elementCount) return BKCurvePathMoveTo;
    BKCurvePathItem it = self.items[index];
    if (control1) *control1 = it.control1;
    if (control2) *control2 = it.control2;
    if (endpoint) *endpoint = it.endpoint;
    return (BKCurvePathElement)it.type;
}

- (BOOL)isEqualToPath:(BKCurvePath *)other
{
    return other != nil && [_items isEqualToData:other->_items];
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[BKCurvePath class]] && [self isEqualToPath:object];
}

- (NSUInteger)hash { return _items.hash; }

- (id)copyWithZone:(NSZone *)zone
{
    BKCurvePath *copy = [[[self class] allocWithZone:zone] init];
    copy->_items = [_items mutableCopy];
    return copy;
}

// What: element list <-> secure archive ("BKCurvePathItems", version 1).
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt32:1 forKey:@"BKCurvePathVersion"];
    [coder encodeObject:_items forKey:@"BKCurvePathItems"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:@"BKCurvePathItems"];
        if (data.length % sizeof(BKCurvePathItem) == 0) _items = [data mutableCopy];
    }
    return self;
}

#pragma mark - The fine polyline

// What: the fine polyline of the whole path (line elements as they are, curve elements flattened with
// the defaults), built once and cached. Why: every measurement and the panorex use this one polyline.
- (const BKCurvePolyline *)polyline
{
    if (_polylineValid) return &_polyline;
    NSUInteger n = self.elementCount;
    const BKCurvePathItem *it = self.items;
    BKVec3d *points = malloc(sizeof(BKVec3d) * (n + 1));
    size_t count = 0, cap = n + 1;
    BOOL failed = (points == NULL);
    BKVec3d last = BKV3d(0, 0, 0);
    for (NSUInteger i = 0; i < n && !failed; i++) {
        if (it[i].type == BKCurvePathCurveTo) {
            BKCurveSegment s = { last, it[i].control1, it[i].control2, it[i].endpoint };
            BKCurvePolyline piece;
            if (!BKCurveFlatten(&s, 1, BK_CURVE_DEFAULT_MAX_SEGMENT_LENGTH, BK_CURVE_DEFAULT_FLATNESS, &piece)) { failed = YES; break; }
            if (count + piece.count > cap) {
                cap = (count + piece.count) * 2;
                BKVec3d *grown = realloc(points, sizeof(BKVec3d) * cap);
                if (!grown) { BKCurvePolylineFree(&piece); failed = YES; break; }
                points = grown;
            }
            for (size_t k = 1; k < piece.count; k++) points[count++] = piece.points[k];   // piece[0] == last
            BKCurvePolylineFree(&piece);
        } else {
            if (count == cap) {
                cap *= 2;
                BKVec3d *grown = realloc(points, sizeof(BKVec3d) * cap);
                if (!grown) { failed = YES; break; }
                points = grown;
            }
            if (count == 0 || BKV3dDistance(points[count - 1], it[i].endpoint) > 0) points[count++] = it[i].endpoint;
        }
        last = it[i].endpoint;
    }
    if (failed) { free(points); points = NULL; count = 0; }
    _polyline.points = points;
    _polyline.count = count;
    _polylineValid = YES;
    return &_polyline;
}

#pragma mark - Measuring

- (double)length { return BKCurvePolylineLength([self polyline]); }

- (double)lengthThroughElementAtIndex:(NSUInteger)index
{
    BKCurvePath *part = [[BKCurvePath alloc] init];
    NSUInteger n = MIN(index + 1, self.elementCount);
    [part->_items appendBytes:self.items length:n * sizeof(BKCurvePathItem)];
    return part.length;
}

- (BKVec3d)vectorAtRelativePosition:(double)r
{
    BKVec3d p = BKV3d(0, 0, 0);
    BKCurvePolylineSampleAt([self polyline], r * self.length, BKV3d(0, 0, 1), &p, NULL, NULL);
    return p;
}

- (BKVec3d)tangentAtRelativePosition:(double)r
{
    BKVec3d t = BKV3d(0, 0, 0);
    BKCurvePolylineSampleAt([self polyline], r * self.length, BKV3d(0, 0, 1), NULL, &t, NULL);
    return t;
}

- (BKVec3d)normalAtRelativePosition:(double)r initialNormal:(BKVec3d)initialNormal
{
    BKVec3d n = BKV3d(0, 0, 0);
    if (self.subpathCount != 1) return n;
    BKCurvePolylineSampleAt([self polyline], r * self.length, initialNormal, NULL, NULL, &n);
    return n;
}

- (BKVec3d)vectorAtStart { const BKCurvePolyline *p = [self polyline]; return p->count ? p->points[0] : BKV3d(0, 0, 0); }
- (BKVec3d)vectorAtEnd { const BKCurvePolyline *p = [self polyline]; return p->count ? p->points[p->count - 1] : BKV3d(0, 0, 0); }

- (BKVec3d)tangentAtStart
{
    const BKCurvePolyline *p = [self polyline];
    if (p->count < 2) return BKV3d(0, 0, 0);
    return BKV3dNormalize(BKV3dSub(p->points[1], p->points[0]));
}

- (BKVec3d)tangentAtEnd
{
    const BKCurvePolyline *p = [self polyline];
    if (p->count < 2) return BKV3d(0, 0, 0);
    return BKV3dNormalize(BKV3dSub(p->points[p->count - 1], p->points[p->count - 2]));
}

- (double)relativePositionClosestToVector:(BKVec3d)v closestVector:(BKVec3d *)closest
{
    return BKCurvePolylineClosestToPoint([self polyline], v, closest, NULL);
}

- (double)relativePositionClosestToLinePoint:(BKVec3d)point direction:(BKVec3d)direction closestVector:(BKVec3d *)closest
{
    return BKCurvePolylineClosestToLine([self polyline], point, direction, closest, NULL);
}

- (NSUInteger)sampleWithSpacing:(double)spacing startDistance:(double)start initialNormal:(BKVec3d)initialNormal
                      positions:(BKVec3d *)positions tangents:(BKVec3d *)tangents normals:(BKVec3d *)normals
                     maxSamples:(NSUInteger)maxSamples
{
    return BKCurvePolylineSample([self polyline], spacing, start, initialNormal, positions, tangents, normals, maxSamples);
}

- (NSUInteger)sampleProjectedWithSpacing:(double)spacing startDistance:(double)start projectionDirection:(BKVec3d)direction
                               positions:(BKVec3d *)positions tangents:(BKVec3d *)tangents normals:(BKVec3d *)normals
                       relativePositions:(double *)relativePositions maxSamples:(NSUInteger)maxSamples
{
    return BKCurvePolylineSampleProjected([self polyline], spacing, start, direction, positions, tangents, normals,
                                          relativePositions, maxSamples);
}

- (double)projectedLengthAlongDirection:(BKVec3d)direction
{
    BKCurvePolyline projected;
    if (!BKCurvePolylineProjectToPlane([self polyline], BKV3d(0, 0, 0), direction, &projected)) return 0;
    double length = BKCurvePolylineLength(&projected);
    BKCurvePolylineFree(&projected);
    return length;
}

- (NSArray<NSValue *> *)intersectionsWithPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
                                  relativePositions:(NSArray<NSNumber *> **)relativePositions
{
    if (self.subpathCount > 1) return [self intersectionsBySubpathWithPlanePoint:planePoint normal:normal relativePositions:relativePositions];
    const BKCurvePolyline *p = [self polyline];
    size_t max = p->count + 1;
    BKVec3d *pts = malloc(sizeof(BKVec3d) * max);
    double *rel = malloc(sizeof(double) * max);
    size_t n = (pts && rel) ? BKCurvePolylinePlaneIntersections(p, planePoint, normal, pts, rel, max) : 0;
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *positions = [NSMutableArray arrayWithCapacity:n];
    for (size_t i = 0; i < n; i++) {
        [points addObject:[NSValue valueWithBytes:&pts[i] objCType:@encode(BKVec3d)]];
        [positions addObject:@(rel[i])];
    }
    free(pts); free(rel);
    if (relativePositions) *relativePositions = positions;
    return points;
}

// What: intersections of a path with several subpaths (moveTo elements after the first). Each subpath is
// intersected on its own, so the invisible jump from one subpath's end to the next moveTo is never
// counted as a crossing (as the classic engine did). Relative positions stay along the whole path's
// joined polyline (the one -length measures), so they agree with -vectorAtRelativePosition:.
- (NSArray<NSValue *> *)intersectionsBySubpathWithPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
                                           relativePositions:(NSArray<NSNumber *> **)relativePositions
{
    NSMutableArray *points = [NSMutableArray array], *positions = [NSMutableArray array];
    double total = self.length, offset = 0;
    BOOL haveEnd = NO;
    BKVec3d previousEnd = BKV3d(0, 0, 0);
    NSUInteger n = self.elementCount, i = 0;
    while (i < n) {
        // one subpath: its moveTo (or the path's first element) up to the next moveTo
        BKCurvePath *sub = [[BKCurvePath alloc] init];
        BKVec3d c1, c2, e;
        for (NSUInteger k = i; k < n; k++) {
            BKCurvePathElement type = [self elementAtIndex:k control1:&c1 control2:&c2 endpoint:&e];
            if (k > i && type == BKCurvePathMoveTo) break;
            if (k == i) {
                if (haveEnd) offset += BKV3dDistance(previousEnd, e);   // the jump is part of the joined polyline
                [sub moveTo:e];
            } else if (type == BKCurvePathCurveTo) [sub curveTo:e control1:c1 control2:c2];
            else [sub lineTo:e];
            i = k + 1;
        }
        NSArray<NSNumber *> *subRel = nil;
        NSArray<NSValue *> *subHits = [sub intersectionsWithPlanePoint:planePoint normal:normal relativePositions:&subRel];
        double subLength = sub.length;
        [points addObjectsFromArray:subHits];
        for (NSNumber *r in subRel) [positions addObject:@(total > 0 ? (offset + r.doubleValue * subLength) / total : 0.0)];
        offset += subLength;
        previousEnd = sub.vectorAtEnd;
        haveEnd = YES;
    }
    if (relativePositions) *relativePositions = positions;
    return points;
}

#pragma mark - Planes

- (BOOL)isPlanar { return BKCurvePolylineIsPlanar([self polyline], 1e-4) ? YES : NO; }

- (BOOL)getLeastSquaresPlanePoint:(BKVec3d *)point normal:(BKVec3d *)normal
{
    return BKCurvePolylineLeastSquaresPlane([self polyline], point, normal) ? YES : NO;
}

- (BKVec3d)topBoundingPointForNormal:(BKVec3d)normal
{
    BKVec3d top = BKV3d(0, 0, 0);
    BKCurvePolylineBoundingPlanes([self polyline], normal, &top, NULL);
    return top;
}

- (BKVec3d)bottomBoundingPointForNormal:(BKVec3d)normal
{
    BKVec3d bottom = BKV3d(0, 0, 0);
    BKCurvePolylineBoundingPlanes([self polyline], normal, NULL, &bottom);
    return bottom;
}

#pragma mark - Changing

// What: rebuilds the element list with each curve element replaced by `block`'s elements.
- (void)replaceCurvesUsing:(void (^)(BKCurveSegment segment, BKCurvePath *into))block
{
    BKCurvePath *rebuilt = [[BKCurvePath alloc] init];
    const BKCurvePathItem *it = self.items;
    BKVec3d last = BKV3d(0, 0, 0);
    for (NSUInteger i = 0; i < self.elementCount; i++) {
        if (it[i].type == BKCurvePathCurveTo) block((BKCurveSegment){ last, it[i].control1, it[i].control2, it[i].endpoint }, rebuilt);
        else [rebuilt addItem:it[i]];
        last = it[i].endpoint;
    }
    _items = rebuilt->_items;
    [self changed];
}

- (void)subdivide:(double)maxSegmentLength
{
    if (!(maxSegmentLength > 0)) return;
    [self replaceCurvesUsing:^(BKCurveSegment s, BKCurvePath *into) {
        double polygon = BKV3dDistance(s.p0, s.c0) + BKV3dDistance(s.c0, s.c1) + BKV3dDistance(s.c1, s.p1);
        NSUInteger pieces = (NSUInteger)MAX(1.0, MIN(65536.0, ceil(polygon / maxSegmentLength)));
        for (NSUInteger k = 0; k < pieces; k++) {
            double t0 = (double)k / pieces, t1 = (double)(k + 1) / pieces, h = (t1 - t0) / 3.0;
            BKVec3d a = BKCurveSegmentPoint(&s, t0), b = (k + 1 == pieces) ? s.p1 : BKCurveSegmentPoint(&s, t1);
            [into curveTo:b control1:BKV3dAddScaled(a, BKCurveSegmentDerivative(&s, t0), h)
                 control2:BKV3dAddScaled(b, BKCurveSegmentDerivative(&s, t1), -h)];
        }
    }];
}

- (void)flatten:(double)flatness
{
    if (!(flatness > 0)) return;
    [self replaceCurvesUsing:^(BKCurveSegment s, BKCurvePath *into) {
        BKCurvePolyline piece;
        if (!BKCurveFlatten(&s, 1, INFINITY, flatness, &piece)) { [into lineTo:s.p1]; return; }
        for (size_t k = 1; k < piece.count; k++) [into lineTo:piece.points[k]];
        if (piece.count < 2) [into lineTo:s.p1];
        BKCurvePolylineFree(&piece);
    }];
}

- (void)applyTransform:(BKCurveTransform)t
{
    BKCurvePathItem *it = (BKCurvePathItem *)_items.mutableBytes;
    for (NSUInteger i = 0; i < self.elementCount; i++) {
        it[i].control1 = BKCurveTransformPoint(t, it[i].control1);
        it[i].control2 = BKCurveTransformPoint(t, it[i].control2);
        it[i].endpoint = BKCurveTransformPoint(t, it[i].endpoint);
    }
    [self changed];
}

- (void)projectToPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
{
    double l = BKV3dLength(normal);
    if (!(l > 0)) return;
    BKVec3d n = BKV3dDiv(normal, l);
    BKCurvePathItem *it = (BKCurvePathItem *)_items.mutableBytes;
    for (NSUInteger i = 0; i < self.elementCount; i++) {
        BKVec3d *v[3] = { &it[i].control1, &it[i].control2, &it[i].endpoint };
        for (int k = 0; k < 3; k++) *v[k] = BKV3dSub(*v[k], BKV3dScale(n, BKV3dDot(BKV3dSub(*v[k], planePoint), n)));
    }
    [self changed];
}

- (void)addEndpointsAtIntersectionsWithPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
{
    [self flatten:BK_CURVE_DEFAULT_FLATNESS];
    double l = BKV3dLength(normal);
    if (!(l > 0)) return;
    BKVec3d n = BKV3dDiv(normal, l);
    BKCurvePath *rebuilt = [[BKCurvePath alloc] init];
    const BKCurvePathItem *it = self.items;
    BKVec3d last = BKV3d(0, 0, 0);
    for (NSUInteger i = 0; i < self.elementCount; i++) {
        if (it[i].type == BKCurvePathLineTo) {
            double s0 = BKV3dDot(BKV3dSub(last, planePoint), n), s1 = BKV3dDot(BKV3dSub(it[i].endpoint, planePoint), n);
            if ((s0 < 0 && s1 > 0) || (s0 > 0 && s1 < 0)) {
                double t = s0 / (s0 - s1);
                [rebuilt lineTo:BKV3dAdd(last, BKV3dScale(BKV3dSub(it[i].endpoint, last), t))];
            }
        }
        [rebuilt addItem:it[i]];
        last = it[i].endpoint;
    }
    _items = rebuilt->_items;
    [self changed];
}

#pragma mark - New paths

- (BKCurvePath *)pathByFlattening:(double)flatness
{
    BKCurvePath *copy = [self copy];
    [copy flatten:flatness];
    return copy;
}

- (BKCurvePath *)pathByProjectingToPlanePoint:(BKVec3d)planePoint normal:(BKVec3d)normal
{
    BKCurvePath *copy = [self copy];
    [copy projectToPlanePoint:planePoint normal:normal];
    return copy;
}

// What: the two outline sides from samples (positions + across directions) and the end point/direction.
- (BKCurvePath *)outlineFromPositions:(const BKVec3d *)positions across:(const BKVec3d *)across count:(NSUInteger)n
                             endPoint:(BKVec3d)end endAcross:(BKVec3d)endAcross distance:(double)distance
{
    BKCurvePath *outline = [[BKCurvePath alloc] init];
    for (int side = 0; side < 2; side++) {
        double d = side == 0 ? distance : -distance;
        for (NSUInteger i = 0; i < n; i++) {
            BKVec3d p = BKV3dAddScaled(positions[i], across[i], d);
            if (i == 0) [outline moveTo:p]; else [outline lineTo:p];
        }
        [outline lineTo:BKV3dAddScaled(end, endAcross, d)];
    }
    return outline;
}

- (BKCurvePath *)outlinePathAtDistance:(double)distance initialNormal:(BKVec3d)initialNormal spacing:(double)spacing
{
    double length = self.length;
    if (self.subpathCount != 1 || !(spacing > 0) || spacing * 2 >= length) return nil;
    NSUInteger max = (NSUInteger)(length / spacing + 1.0);
    BKVec3d *pos = malloc(sizeof(BKVec3d) * max), *nor = malloc(sizeof(BKVec3d) * max);
    if (!pos || !nor) { free(pos); free(nor); return nil; }
    NSUInteger n = [self sampleWithSpacing:spacing startDistance:0 initialNormal:initialNormal positions:pos tangents:NULL normals:nor maxSamples:max];
    BKCurvePath *outline = nil;
    if (n > 0) {
        BKVec3d endTangent = self.tangentAtEnd;
        BKVec3d endAcross = BKV3dSub(nor[n - 1], BKV3dScale(endTangent, BKV3dDot(nor[n - 1], endTangent)));
        double l = BKV3dLength(endAcross);
        endAcross = l > 0 ? BKV3dDiv(endAcross, l) : nor[n - 1];
        outline = [self outlineFromPositions:pos across:nor count:n endPoint:self.vectorAtEnd endAcross:endAcross distance:distance];
    }
    free(pos); free(nor);
    return outline;
}

- (BKCurvePath *)outlinePathAtDistance:(double)distance projectionNormal:(BKVec3d)projectionNormal spacing:(double)spacing
{
    double length = self.length;
    if (self.subpathCount != 1 || !(spacing > 0) || spacing * 2 >= length) return nil;
    NSUInteger max = (NSUInteger)(length / spacing + 1.0);
    BKVec3d *pos = malloc(sizeof(BKVec3d) * max), *tan = malloc(sizeof(BKVec3d) * max);
    if (!pos || !tan) { free(pos); free(tan); return nil; }
    NSUInteger n = [self sampleWithSpacing:spacing startDistance:0 initialNormal:BKV3d(0, 0, 1) positions:pos tangents:tan normals:NULL maxSamples:max];
    BKCurvePath *outline = nil;
    if (n > 0) {
        for (NSUInteger i = 0; i < n; i++) {
            BKVec3d a = BKV3dCross(projectionNormal, tan[i]);
            double l = BKV3dLength(a);
            tan[i] = l > 0 ? BKV3dDiv(a, l) : BKV3d(0, 0, 0);   // across = unit(projectionNormal x tangent)
        }
        BKVec3d e = BKV3dCross(projectionNormal, self.tangentAtEnd);
        double l = BKV3dLength(e);
        e = l > 0 ? BKV3dDiv(e, l) : BKV3d(0, 0, 0);
        outline = [self outlineFromPositions:pos across:tan count:n endPoint:self.vectorAtEnd endAcross:e distance:distance];
    }
    free(pos); free(tan);
    return outline;
}

@end
