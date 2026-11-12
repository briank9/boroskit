// BorosKit accuracy check: phantom builder and measuring tools (see BKPhantom.h).

#import "BKPhantom.h"
#import <math.h>

// Voxel size (mm) along the grid's rows, columns and slices: deliberately not cubic.
static const double kSpacingX = 0.3, kSpacingY = 0.4, kSpacingZ = 0.5;
// Half the size of the voxel grid along its own three axes (mm): large enough that every
// marker stays well inside, even when the grid is tilted.
static const double kHalfX = 30.0, kHalfY = 27.0, kHalfZ = 27.0;
static const float kBackground = -1000.0f;
// Soft dots: Gaussian blobs with this width (mm). Measurable to a fraction of a voxel.
static const double kDotSigma = 0.8;

// ---- small vector helpers (plain C, written here so the test does not depend on the
// engine for its own reference math) ----
static N3Vector V(double x, double y, double z) { return N3VectorMake(x, y, z); }
static N3Vector Add(N3Vector a, N3Vector b) { return V(a.x + b.x, a.y + b.y, a.z + b.z); }
static N3Vector Sub(N3Vector a, N3Vector b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
static N3Vector Mul(N3Vector a, double s) { return V(a.x * s, a.y * s, a.z * s); }
static double Dot(N3Vector a, N3Vector b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static double Len(N3Vector a) { return sqrt(Dot(a, a)); }
static N3Vector Cross(N3Vector a, N3Vector b)
{
    return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
static N3Vector Unit(N3Vector a) { return Mul(a, 1.0 / Len(a)); }
// Rotates v about the unit axis by `degrees` (Rodrigues' formula).
static N3Vector Rotate(N3Vector v, N3Vector axis, double degrees)
{
    double t = degrees * M_PI / 180.0, c = cos(t), s = sin(t);
    return Add(Add(Mul(v, c), Mul(Cross(axis, v), s)), Mul(axis, Dot(axis, v) * (1.0 - c)));
}
static double Clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

@implementation BKPhantomMarker
@end

@implementation BKPhantom {
    float *_voxels;               // owned by _volume (freeWhenDone), kept for the CPU reference
    NSUInteger _nx, _ny, _nz;
    N3Vector _origin;             // patient position of voxel (0,0,0)'s centre
    N3Vector _rowDir, _colDir, _sliceDir;   // unit patient directions of the voxel axes
    N3Vector _relDot[4];          // dot centres relative to C (A1, B1, A2, B2)
}

+ (NSString *)nameOfGrid:(BKPhantomGrid)grid
{
    switch (grid) {
        case BKPhantomGridAxisAligned: return @"axis-aligned";
        case BKPhantomGridTilted:      return @"tilted 17deg";
        case BKPhantomGridReversed:    return @"reversed (rows to the right, slices to the feet)";
    }
    return @"?";
}

// Built once per grid type for the whole test run: the three phantoms take about a
// second each to fill in a debug build, and they never change.
+ (BKPhantom *)phantomWithGrid:(BKPhantomGrid)grid
{
    static NSMutableDictionary<NSNumber *, BKPhantom *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        BKPhantom *p = cache[@(grid)];
        if (!p) {
            p = [[BKPhantom alloc] initWithGrid:grid];
            cache[@(grid)] = p;
        }
        return p;
    }
}

// Makes one marker with its measuring box (the marker's extent plus nothing else).
static BKPhantomMarker *MakeMarker(NSString *name, N3Vector centre, float value, N3Vector halfSize)
{
    BKPhantomMarker *m = [[BKPhantomMarker alloc] init];
    m.name = name;
    m.centre = centre;
    m.value = value;
    m.boxMin = Sub(centre, halfSize);
    m.boxMax = Add(centre, halfSize);
    return m;
}

- (instancetype)initWithGrid:(BKPhantomGrid)grid
{
    if (!(self = [super init])) return nil;
    _grid = grid;
    _background = kBackground;
    _spacingX = kSpacingX; _spacingY = kSpacingY; _spacingZ = kSpacingZ;
    // A deliberately "random-looking" centre far from 0, like a real scanner origin.
    _centre = V(10.7, -23.3, 41.9);

    // The three voxel-axis directions in patient space for each grid type.
    switch (grid) {
        case BKPhantomGridAxisAligned:
            _rowDir = V(1, 0, 0); _colDir = V(0, 1, 0); _sliceDir = V(0, 0, 1);
            break;
        case BKPhantomGridTilted: {
            N3Vector axis = Unit(V(1, 1, 0.5));
            _rowDir = Rotate(V(1, 0, 0), axis, 17);
            _colDir = Rotate(V(0, 1, 0), axis, 17);
            _sliceDir = Rotate(V(0, 0, 1), axis, 17);
            break;
        }
        case BKPhantomGridReversed:
            _rowDir = V(-1, 0, 0); _colDir = V(0, 1, 0); _sliceDir = V(0, 0, -1);
            break;
    }

    _nx = (NSUInteger)lround(2 * kHalfX / kSpacingX) + 1;   // 201
    _ny = (NSUInteger)lround(2 * kHalfY / kSpacingY) + 1;   // 136
    _nz = (NSUInteger)lround(2 * kHalfZ / kSpacingZ) + 1;   // 109
    double ci = 0.5 * (_nx - 1), cj = 0.5 * (_ny - 1), ck = 0.5 * (_nz - 1);
    _origin = Sub(Sub(Sub(_centre, Mul(_rowDir, ci * kSpacingX)), Mul(_colDir, cj * kSpacingY)), Mul(_sliceDir, ck * kSpacingZ));

    // Markers (relative to C), as described in the header.
    double d = 40.0 / (2.0 * sqrt(2.0));   // 14.142 mm: makes pair 2 exactly 40 mm apart
    _relDot[0] = V(-20, 8, -10);
    _relDot[1] = V(20, 8, -10);
    _relDot[2] = V(-8, -d, -d);
    _relDot[3] = V(-8, d, d);
    N3Vector C = _centre;
    N3Vector dotHalf = V(3, 3, 3);   // 3 mm = almost 4 dot widths: the whole dot
    _markers = @{
        @"left":     MakeMarker(@"left", Add(C, V(12, 0, 0)), 1000, V(3.5, 3.5, 3.5)),
        @"anterior": MakeMarker(@"anterior", Add(C, V(0, -12, 0)), 500, V(3.5, 3.5, 3.5)),
        @"rod":      MakeMarker(@"rod", Add(C, V(0, 0, 13)), 200, V(2, 2, 7)),
        @"dotA1":    MakeMarker(@"dotA1", Add(C, _relDot[0]), 2000, dotHalf),
        @"dotB1":    MakeMarker(@"dotB1", Add(C, _relDot[1]), 2000, dotHalf),
        @"dotA2":    MakeMarker(@"dotA2", Add(C, _relDot[2]), 1500, dotHalf),
        @"dotB2":    MakeMarker(@"dotB2", Add(C, _relDot[3]), 1500, dotHalf),
    };

    // Fill every voxel with the ideal value at its centre.
    NSUInteger count = _nx * _ny * _nz;
    _voxels = malloc(sizeof(float) * count);
    for (NSUInteger k = 0; k < _nz; k++)
        for (NSUInteger j = 0; j < _ny; j++) {
            N3Vector rowStart = Add(Add(_origin, Mul(_colDir, j * kSpacingY)), Mul(_sliceDir, k * kSpacingZ));
            for (NSUInteger i = 0; i < _nx; i++) {
                N3Vector p = Add(rowStart, Mul(_rowDir, i * kSpacingX));
                _voxels[(k * _ny + j) * _nx + i] = [self analyticValueAt:p];
            }
        }

    double orientation[9] = { _rowDir.x, _rowDir.y, _rowDir.z, _colDir.x, _colDir.y, _colDir.z,
                              _sliceDir.x, _sliceDir.y, _sliceDir.z };
    _volume = [[CPRVolumeData alloc] initWithFloatBytesNoCopy:_voxels pixelsWide:_nx pixelsHigh:_ny pixelsDeep:_nz
                                                       origin:_origin orientation:orientation
                                                     spacingX:kSpacingX spacingY:kSpacingY spacingZ:kSpacingZ
                                                 freeWhenDone:YES];
    return self;
}

- (BKPhantomMarker *)marker:(NSString *)name
{
    BKPhantomMarker *m = _markers[name];
    NSAssert(m, @"no marker %@", name);
    return m;
}

// The ideal phantom: background plus the brightest marker contribution at p.
// Spheres and the rod have a 1 mm soft edge centred on their radius (so a radius-3
// sphere goes from full value at 2.5 mm to background at 3.5 mm).
- (float)analyticValueAt:(N3Vector)p
{
    N3Vector q = Sub(p, _centre);
    double best = 0;   // 0..(peak - background) above the background

    double dl = Len(Sub(q, V(12, 0, 0)));
    if (dl < 3.5) best = fmax(best, 2000.0 * Clamp01(3.5 - dl));        // left sphere, 1000
    double da = Len(Sub(q, V(0, -12, 0)));
    if (da < 3.5) best = fmax(best, 1500.0 * Clamp01(3.5 - da));        // anterior sphere, 500
    // rod: distance to the segment z = 8..18 on the axis
    double zc = fmin(fmax(q.z, 8.0), 18.0);
    double dr = Len(Sub(q, V(0, 0, zc)));
    if (dr < 2.0) best = fmax(best, 1200.0 * Clamp01(2.0 - dr));        // rod, 200
    for (int i = 0; i < 4; i++) {
        double dd = Len(Sub(q, _relDot[i]));
        if (dd < 4.0) {
            double peak = (i < 2 ? 2000.0 : 1500.0) - kBackground;
            best = fmax(best, peak * exp(-dd * dd / (2.0 * kDotSigma * kDotSigma)));
        }
    }
    return (float)(kBackground + best);
}

// Patient point -> fractional voxel indices, from the grid's own origin/directions/spacing.
- (N3Vector)voxelCoordinatesOf:(N3Vector)p
{
    N3Vector d = Sub(p, _origin);
    return V(Dot(d, _rowDir) / kSpacingX, Dot(d, _colDir) / kSpacingY, Dot(d, _sliceDir) / kSpacingZ);
}

- (BOOL)containsPoint:(N3Vector)p marginVoxels:(double)margin
{
    N3Vector v = [self voxelCoordinatesOf:p];
    return v.x >= margin && v.y >= margin && v.z >= margin &&
           v.x <= _nx - 1 - margin && v.y <= _ny - 1 - margin && v.z <= _nz - 1 - margin;
}

// Textbook trilinear interpolation: blend the 8 surrounding voxels by distance.
- (float)referenceTrilinearAt:(N3Vector)p
{
    N3Vector v = [self voxelCoordinatesOf:p];
    if (!(v.x >= 0 && v.y >= 0 && v.z >= 0 && v.x <= _nx - 1 && v.y <= _ny - 1 && v.z <= _nz - 1))
        return NAN;
    NSUInteger i0 = MIN((NSUInteger)floor(v.x), _nx - 2);
    NSUInteger j0 = MIN((NSUInteger)floor(v.y), _ny - 2);
    NSUInteger k0 = MIN((NSUInteger)floor(v.z), _nz - 2);
    double fx = v.x - i0, fy = v.y - j0, fz = v.z - k0;
    double result = 0;
    for (int c = 0; c < 8; c++) {
        NSUInteger i = i0 + (c & 1), j = j0 + ((c >> 1) & 1), k = k0 + ((c >> 2) & 1);
        double w = ((c & 1) ? fx : 1 - fx) * (((c >> 1) & 1) ? fy : 1 - fy) * (((c >> 2) & 1) ? fz : 1 - fz);
        result += w * _voxels[(k * _ny + j) * _nx + i];
    }
    return (float)result;
}

@end

#pragma mark - Measuring tools

N3Vector BKImagePlanePointAt(BKImagePlane plane, double i, double j)
{
    return Add(Add(plane.centre, Mul(plane.right, (i + 0.5 - 0.5 * plane.width) * plane.spacing)),
               Mul(plane.down, (j + 0.5 - 0.5 * plane.height) * plane.spacing));
}

CGPoint BKImagePlaneProject(BKImagePlane plane, N3Vector p)
{
    N3Vector d = Sub(p, plane.centre);
    return CGPointMake(Dot(d, plane.right) / plane.spacing + 0.5 * plane.width - 0.5,
                       Dot(d, plane.down) / plane.spacing + 0.5 * plane.height - 0.5);
}

CGRect BKImagePlaneProjectBox(BKImagePlane plane, N3Vector lo, N3Vector hi, double marginMM)
{
    double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    for (int c = 0; c < 8; c++) {
        N3Vector corner = V((c & 1) ? hi.x : lo.x, (c & 2) ? hi.y : lo.y, (c & 4) ? hi.z : lo.z);
        CGPoint q = BKImagePlaneProject(plane, corner);
        minX = fmin(minX, q.x); maxX = fmax(maxX, q.x);
        minY = fmin(minY, q.y); maxY = fmax(maxY, q.y);
    }
    double m = marginMM / plane.spacing;
    minX = floor(minX - m); minY = floor(minY - m);
    maxX = ceil(maxX + m);  maxY = ceil(maxY + m);
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

CGPoint BKBrightSpotCentroid(const float *pixels, NSUInteger width, NSUInteger height,
                             CGRect box, float background, float *peak)
{
    long x0 = MAX(0L, (long)CGRectGetMinX(box)), y0 = MAX(0L, (long)CGRectGetMinY(box));
    long x1 = MIN((long)width - 1, (long)CGRectGetMaxX(box)), y1 = MIN((long)height - 1, (long)CGRectGetMaxY(box));
    double sw = 0, sx = 0, sy = 0;
    float best = -INFINITY;
    for (long y = y0; y <= y1; y++)
        for (long x = x0; x <= x1; x++) {
            float v = pixels[y * width + x];
            if (isnan(v)) continue;
            best = fmaxf(best, v);
            double w = v - background;
            if (w <= 0) continue;
            sw += w; sx += w * x; sy += w * y;
        }
    if (peak) *peak = best;
    if (sw <= 0) return CGPointMake(NAN, NAN);
    return CGPointMake(sx / sw, sy / sw);
}

void BKErrorStatsAdd(BKErrorStats *stats, double a, double b)
{
    double e = fabs(a - b);
    stats->maxError = fmax(stats->maxError, e);
    stats->sumError += e;
    stats->count++;
}

double BKErrorStatsMean(BKErrorStats stats)
{
    return stats.count ? stats.sumError / stats.count : 0;
}

void BKReport(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "ACCURACY | %s\n", line.UTF8String);
}
