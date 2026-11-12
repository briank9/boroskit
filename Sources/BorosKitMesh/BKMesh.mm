// BorosKitMesh: BKMesh implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * A mesh is a 3D surface made of small triangles, like the skin of a 3D-printed bone
 * model. This file stores those triangles and answers simple questions about them:
 * how big is the shape, is its surface closed without holes, what is its area and
 * volume. It can also move the shape (e.g. to place an implant), work out the
 * "outward" directions used for lighting, and tidy up files where every triangle
 * carries its own copy of each corner (STL files).
 * It is written in Objective-C++ only to use C++'s fast sorting and hash tables, so
 * meshes with millions of triangles (intraoral scans) are still checked quickly.
 */

#import "BKMesh.h"
#import <vector>
#import <unordered_map>
#import <algorithm>
#import <cmath>

NSErrorDomain const BKMeshErrorDomain = @"BKMeshErrorDomain";

// Makes an NSError in the mesh domain with a plain-language message.
static NSError *BKMeshError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKMeshErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// What: YES if all three coordinates are ordinary numbers (not NaN / infinity).
// Why: one bad number in a file would break the bounds, the camera fit and the GPU.
static inline bool BKFinite3(simd_float3 v)
{
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

@implementation BKMesh {
    std::vector<simd_float3> _vertexStore;
    std::vector<uint32_t> _indexStore;
    std::vector<simd_float3> _normalStore;   // empty = no normals
    std::vector<simd_float4> _colorStore;    // empty = no colours
}

- (instancetype)init
{
    return [super init];
}

// What: copies and checks the arrays (see header).
// Why: meshes mostly come from files, so every number is checked once here and the
// rest of the code (and the GPU) can trust that indices are in range.
- (instancetype)initWithVertices:(const simd_float3 *)vertices vertexCount:(NSUInteger)vertexCount
                         indices:(const uint32_t *)indices indexCount:(NSUInteger)indexCount
                         normals:(const simd_float3 *)normals colors:(const simd_float4 *)colors
                           error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    if (indexCount % 3 != 0) {
        if (error) *error = BKMeshError(BKMeshErrorInvalidGeometry, @"The triangle list is incomplete (its length is not a multiple of 3).");
        return nil;
    }
    if (vertexCount > UINT32_MAX) {
        if (error) *error = BKMeshError(BKMeshErrorInvalidGeometry, @"The mesh has too many vertices (more than 4 billion).");
        return nil;
    }
    if ((vertexCount && !vertices) || (indexCount && !indices)) {
        if (error) *error = BKMeshError(BKMeshErrorInvalidGeometry, @"The mesh data is missing.");
        return nil;
    }
    for (NSUInteger i = 0; i < vertexCount; i++) {
        if (!BKFinite3(vertices[i])) {
            if (error) *error = BKMeshError(BKMeshErrorInvalidGeometry,
                                            [NSString stringWithFormat:@"Vertex %lu has an invalid coordinate (not a number or infinite).", (unsigned long)i]);
            return nil;
        }
    }
    for (NSUInteger i = 0; i < indexCount; i++) {
        if (indices[i] >= vertexCount) {
            if (error) *error = BKMeshError(BKMeshErrorInvalidGeometry,
                                            [NSString stringWithFormat:@"Triangle %lu refers to vertex %u, but there are only %lu vertices.",
                                             (unsigned long)(i / 3), indices[i], (unsigned long)vertexCount]);
            return nil;
        }
    }
    _vertexStore.assign(vertices, vertices + vertexCount);
    _indexStore.assign(indices, indices + indexCount);
    if (normals) {
        _normalStore.assign(normals, normals + vertexCount);
        // Bad normals are not fatal (they only affect lighting): replace them.
        for (auto &n : _normalStore)
            if (!BKFinite3(n)) n = simd_make_float3(0, 0, 0);
    }
    if (colors) _colorStore.assign(colors, colors + vertexCount);
    return self;
}

// What: a full independent copy. Why: callers (e.g. "duplicate implant") must be able
// to change a copy without touching the original.
- (id)copyWithZone:(NSZone *)zone
{
    BKMesh *copy = [[[self class] allocWithZone:zone] init];
    copy->_vertexStore = _vertexStore;
    copy->_indexStore = _indexStore;
    copy->_normalStore = _normalStore;
    copy->_colorStore = _colorStore;
    copy->_name = [_name copy];
    return copy;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<BKMesh %p '%@': %lu vertices, %lu triangles%@%@>", self, _name ?: @"",
            (unsigned long)self.vertexCount, (unsigned long)self.triangleCount,
            _normalStore.empty() ? @"" : @", normals", _colorStore.empty() ? @"" : @", colours"];
}

#pragma mark - Data access

- (NSUInteger)vertexCount { return _vertexStore.size(); }
- (NSUInteger)triangleCount { return _indexStore.size() / 3; }
- (const simd_float3 *)vertices { return _vertexStore.data(); }
- (const uint32_t *)indices { return _indexStore.data(); }
- (const simd_float3 *)normals { return _normalStore.empty() ? NULL : _normalStore.data(); }
- (const simd_float4 *)colors { return _colorStore.empty() ? NULL : _colorStore.data(); }

// What: records that the mesh changed. Why: see `version` in the header.
- (void)touch
{
    _version++;
}

- (void)setNormals:(const simd_float3 *)normals
{
    if (normals && !_vertexStore.empty()) _normalStore.assign(normals, normals + _vertexStore.size());
    else _normalStore.clear();
    [self touch];
}

- (void)setColors:(const simd_float4 *)colors
{
    if (colors && !_vertexStore.empty()) _colorStore.assign(colors, colors + _vertexStore.size());
    else _colorStore.clear();
    [self touch];
}

#pragma mark - Bounds

// What: smallest/largest coordinate over all vertices. Why: fitting the camera,
// placing labels, and quick "is it where I expect" checks.
- (simd_float3)boundsMin
{
    if (_vertexStore.empty()) return simd_make_float3(0, 0, 0);
    simd_float3 m = _vertexStore[0];
    for (const auto &v : _vertexStore) m = simd_min(m, v);
    return m;
}

- (simd_float3)boundsMax
{
    if (_vertexStore.empty()) return simd_make_float3(0, 0, 0);
    simd_float3 m = _vertexStore[0];
    for (const auto &v : _vertexStore) m = simd_max(m, v);
    return m;
}

#pragma mark - Transform

+ (simd_float4x4)matrixFromN3AffineTransform:(N3AffineTransform)t
{
    // N3AffineTransform (CATransform3D) multiplies row vectors: x' = x*m11 + y*m21 + z*m31 + m41.
    // simd multiplies column vectors, so its columns are the rows of the N3 matrix.
    return simd_matrix(simd_make_float4(t.m11, t.m12, t.m13, t.m14),
                       simd_make_float4(t.m21, t.m22, t.m23, t.m24),
                       simd_make_float4(t.m31, t.m32, t.m33, t.m34),
                       simd_make_float4(t.m41, t.m42, t.m43, t.m44));
}

- (void)transformByN3AffineTransform:(N3AffineTransform)transform
{
    [self transformByMatrix:[[self class] matrixFromN3AffineTransform:transform]];
}

// What: applies the matrix to points (with translation) and normals (without; using
// the inverse-transpose so they stay perpendicular to the surface even when the
// matrix stretches unevenly). Why: see header.
- (void)transformByMatrix:(simd_float4x4)m
{
    for (auto &v : _vertexStore) {
        simd_float4 p = simd_mul(m, simd_make_float4(v, 1.0f));
        // A projective matrix (last row not 0,0,0,1) is divided out like VTK does.
        if (p.w != 0.0f && p.w != 1.0f) p /= p.w;
        v = p.xyz;
    }
    simd_float3x3 linear = simd_matrix(m.columns[0].xyz, m.columns[1].xyz, m.columns[2].xyz);
    float det = simd_determinant(linear);
    if (!_normalStore.empty() && det != 0.0f) {
        simd_float3x3 normalMatrix = simd_transpose(simd_inverse(linear));
        for (auto &n : _normalStore) {
            simd_float3 t = simd_mul(normalMatrix, n);
            float len = simd_length(t);
            n = len > 0 ? t / len : t;
        }
    }
    // A mirror turns anticlockwise corners into clockwise ones; swap two corners so
    // the outside of the shape is still recognised as the outside.
    if (det < 0.0f) {
        for (size_t i = 0; i + 2 < _indexStore.size(); i += 3)
            std::swap(_indexStore[i + 1], _indexStore[i + 2]);
    }
    [self touch];
}

#pragma mark - Normals

// What: the triangle's "area vector": its outward direction, length = 2 x its area.
static inline simd_float3 BKTriangleCross(const std::vector<simd_float3> &v, uint32_t a, uint32_t b, uint32_t c)
{
    return simd_cross(v[b] - v[a], v[c] - v[a]);
}

- (void)computeSmoothNormals
{
    std::vector<simd_float3> sum(_vertexStore.size(), simd_make_float3(0, 0, 0));
    for (size_t i = 0; i + 2 < _indexStore.size(); i += 3) {
        uint32_t a = _indexStore[i], b = _indexStore[i + 1], c = _indexStore[i + 2];
        // Not normalised on purpose: bigger triangles count more (area weighting).
        simd_float3 n = BKTriangleCross(_vertexStore, a, b, c);
        sum[a] += n; sum[b] += n; sum[c] += n;
    }
    for (auto &n : sum) {
        float len = simd_length(n);
        n = len > 0 ? n / len : simd_make_float3(0, 0, 0);
    }
    _normalStore.swap(sum);
    [self touch];
}

- (void)computeFlatNormals
{
    size_t triangles = _indexStore.size() / 3;
    std::vector<simd_float3> vertices(triangles * 3), normals(triangles * 3);
    std::vector<simd_float4> colors(_colorStore.empty() ? 0 : triangles * 3);
    std::vector<uint32_t> indices(triangles * 3);
    for (size_t t = 0; t < triangles; t++) {
        uint32_t a = _indexStore[3 * t], b = _indexStore[3 * t + 1], c = _indexStore[3 * t + 2];
        simd_float3 n = BKTriangleCross(_vertexStore, a, b, c);
        float len = simd_length(n);
        n = len > 0 ? n / len : simd_make_float3(0, 0, 0);
        uint32_t corners[3] = {a, b, c};
        for (int k = 0; k < 3; k++) {
            size_t out = 3 * t + k;
            vertices[out] = _vertexStore[corners[k]];
            normals[out] = n;
            if (!colors.empty()) colors[out] = _colorStore[corners[k]];
            indices[out] = (uint32_t)out;
        }
    }
    _vertexStore.swap(vertices);
    _normalStore.swap(normals);
    _colorStore.swap(colors);
    _indexStore.swap(indices);
    [self touch];
}

#pragma mark - Welding

// Hash for a grid cell / exact position key.
struct BKCellKey {
    int64_t x, y, z;
    bool operator==(const BKCellKey &o) const { return x == o.x && y == o.y && z == o.z; }
};
struct BKCellKeyHash {
    size_t operator()(const BKCellKey &k) const {
        uint64_t h = (uint64_t)k.x * 0x9E3779B97F4A7C15ULL;
        h ^= (uint64_t)k.y * 0xC2B2AE3D27D4EB4FULL + (h << 6) + (h >> 2);
        h ^= (uint64_t)k.z * 0x165667B19E3779F9ULL + (h << 6) + (h >> 2);
        return (size_t)h;
    }
};

// What: exact key of a point (its bit pattern; -0 and +0 treated as the same).
static BKCellKey BKExactKey(simd_float3 v)
{
    simd_float3 p = v + 0.0f;   // turns -0 into +0
    float fx = p.x, fy = p.y, fz = p.z;   // vector lanes have no address of their own
    uint32_t bx, by, bz;
    memcpy(&bx, &fx, 4); memcpy(&by, &fy, 4); memcpy(&bz, &fz, 4);
    return BKCellKey{(int64_t)bx, (int64_t)by, (int64_t)bz};
}

- (NSUInteger)weldVerticesWithTolerance:(float)tolerance
{
    size_t n = _vertexStore.size();
    if (n == 0) return 0;
    if (!(tolerance >= 0) || !std::isfinite(tolerance)) tolerance = 0;

    // 1. For every vertex, find the "representative" vertex it merges into.
    std::vector<uint32_t> representative(n);
    if (tolerance == 0) {
        std::unordered_map<BKCellKey, uint32_t, BKCellKeyHash> seen;
        seen.reserve(n);
        for (size_t i = 0; i < n; i++) {
            auto ins = seen.emplace(BKExactKey(_vertexStore[i]), (uint32_t)i);
            representative[i] = ins.first->second;
        }
    } else {
        // Grid of cells `tolerance` wide: a close neighbour can only be in the same or
        // one of the 26 surrounding cells, so each vertex checks just those.
        std::unordered_map<BKCellKey, std::vector<uint32_t>, BKCellKeyHash> grid;
        grid.reserve(n);
        float tol2 = tolerance * tolerance;
        for (size_t i = 0; i < n; i++) {
            simd_float3 v = _vertexStore[i];
            BKCellKey cell = {(int64_t)std::floor(v.x / tolerance), (int64_t)std::floor(v.y / tolerance), (int64_t)std::floor(v.z / tolerance)};
            uint32_t found = (uint32_t)i;
            for (int dx = -1; dx <= 1 && found == i; dx++)
                for (int dy = -1; dy <= 1 && found == i; dy++)
                    for (int dz = -1; dz <= 1 && found == i; dz++) {
                        auto it = grid.find(BKCellKey{cell.x + dx, cell.y + dy, cell.z + dz});
                        if (it == grid.end()) continue;
                        for (uint32_t j : it->second)
                            if (simd_distance_squared(_vertexStore[j], v) <= tol2) { found = j; break; }
                    }
            representative[i] = found;
            if (found == i) grid[cell].push_back((uint32_t)i);
        }
    }

    // 2. Rewrite the triangles to use representatives; drop collapsed ones.
    std::vector<uint32_t> indices;
    indices.reserve(_indexStore.size());
    for (size_t i = 0; i + 2 < _indexStore.size(); i += 3) {
        uint32_t a = representative[_indexStore[i]], b = representative[_indexStore[i + 1]], c = representative[_indexStore[i + 2]];
        if (a == b || b == c || a == c) continue;
        indices.push_back(a); indices.push_back(b); indices.push_back(c);
    }

    // 3. Keep only vertices that a triangle still uses, in their original order.
    const uint32_t unused = UINT32_MAX;
    std::vector<uint32_t> newIndex(n, unused);
    for (uint32_t i : indices) newIndex[i] = 0;
    std::vector<simd_float3> vertices, normals;
    std::vector<simd_float4> colors;
    for (size_t i = 0; i < n; i++) {
        if (newIndex[i] == unused) continue;
        newIndex[i] = (uint32_t)vertices.size();
        vertices.push_back(_vertexStore[i]);
        if (!_colorStore.empty()) colors.push_back(_colorStore[i]);
        if (!_normalStore.empty()) normals.push_back(simd_make_float3(0, 0, 0));
    }
    // Merged normals: average of the group.
    if (!_normalStore.empty())
        for (size_t i = 0; i < n; i++)
            if (newIndex[representative[i]] != unused) normals[newIndex[representative[i]]] += _normalStore[i];
    for (auto &nv : normals) {
        float len = simd_length(nv);
        if (len > 0) nv /= len;
    }
    for (auto &i : indices) i = newIndex[i];

    NSUInteger removed = n - vertices.size();
    _vertexStore.swap(vertices);
    _normalStore.swap(normals);
    _colorStore.swap(colors);
    _indexStore.swap(indices);
    [self touch];
    return removed;
}

#pragma mark - Checks

// What: counts edge problems (see BKMeshEdgeReport).
// How: every triangle edge is written down as (smaller vertex, larger vertex) plus the
// direction it was walked in; after sorting, equal edges sit together and are counted.
- (BKMeshEdgeReport)edgeReport
{
    BKMeshEdgeReport report = {0, 0, 0, 0, 0};
    struct Edge { uint64_t key; int32_t dir; };
    std::vector<Edge> edges;
    edges.reserve(_indexStore.size());
    for (size_t i = 0; i + 2 < _indexStore.size(); i += 3) {
        uint32_t c[3] = {_indexStore[i], _indexStore[i + 1], _indexStore[i + 2]};
        if (c[0] == c[1] || c[1] == c[2] || c[0] == c[2]) { report.degenerateTriangleCount++; continue; }
        for (int k = 0; k < 3; k++) {
            uint32_t a = c[k], b = c[(k + 1) % 3];
            uint64_t lo = std::min(a, b), hi = std::max(a, b);
            edges.push_back(Edge{(lo << 32) | hi, a < b ? 1 : -1});
        }
    }
    std::sort(edges.begin(), edges.end(), [](const Edge &x, const Edge &y) { return x.key < y.key; });
    for (size_t i = 0; i < edges.size();) {
        size_t j = i;
        int32_t balance = 0;
        while (j < edges.size() && edges[j].key == edges[i].key) { balance += edges[j].dir; j++; }
        size_t uses = j - i;
        report.edgeCount++;
        if (uses == 1) report.boundaryEdgeCount++;
        else if (uses > 2) report.nonManifoldEdgeCount++;
        // Two neighbours walking a shared edge the SAME way = one of them is flipped.
        else if (balance != 0) report.misorientedEdgeCount++;
        i = j;
    }
    return report;
}

- (BOOL)isWatertight
{
    if (self.triangleCount == 0) return NO;
    BKMeshEdgeReport r = [self edgeReport];
    return r.boundaryEdgeCount == 0 && r.nonManifoldEdgeCount == 0;
}

- (BOOL)isManifold
{
    return [self edgeReport].nonManifoldEdgeCount == 0;
}

// Sums in double precision: millions of small triangles would lose accuracy in float.
- (double)surfaceArea
{
    double area = 0;
    for (size_t i = 0; i + 2 < _indexStore.size(); i += 3) {
        simd_double3 a = simd_double(_vertexStore[_indexStore[i]]);
        simd_double3 b = simd_double(_vertexStore[_indexStore[i + 1]]);
        simd_double3 c = simd_double(_vertexStore[_indexStore[i + 2]]);
        area += 0.5 * simd_length(simd_cross(b - a, c - a));
    }
    return area;
}

// Each triangle plus the origin forms a small pyramid; adding their signed volumes
// gives the enclosed volume (parts outside the shape cancel out).
- (double)enclosedVolume
{
    double volume = 0;
    for (size_t i = 0; i + 2 < _indexStore.size(); i += 3) {
        simd_double3 a = simd_double(_vertexStore[_indexStore[i]]);
        simd_double3 b = simd_double(_vertexStore[_indexStore[i + 1]]);
        simd_double3 c = simd_double(_vertexStore[_indexStore[i + 2]]);
        volume += simd_dot(a, simd_cross(b, c)) / 6.0;
    }
    return volume;
}

#pragma mark - Simple shapes

+ (BKMesh *)boxMeshWithMin:(simd_float3)lo max:(simd_float3)hi
{
    // Vertex number = (x is max ? 1 : 0) + (y is max ? 2 : 0) + (z is max ? 4 : 0).
    simd_float3 v[8];
    for (int i = 0; i < 8; i++)
        v[i] = simd_make_float3((i & 1) ? hi.x : lo.x, (i & 2) ? hi.y : lo.y, (i & 4) ? hi.z : lo.z);
    // Two triangles per face, anticlockwise seen from outside.
    static const uint32_t idx[36] = {
        0, 2, 1,  1, 2, 3,   // -z
        4, 5, 6,  5, 7, 6,   // +z
        0, 1, 4,  1, 5, 4,   // -y
        2, 6, 3,  3, 6, 7,   // +y
        0, 4, 2,  2, 4, 6,   // -x
        1, 3, 5,  3, 7, 5,   // +x
    };
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v vertexCount:8 indices:idx indexCount:36 normals:NULL colors:NULL error:NULL];
    // An inverted box (min > max on an odd number of axes) would face inward: fix it.
    if (mesh.enclosedVolume < 0)
        for (size_t i = 0; i + 2 < mesh->_indexStore.size(); i += 3) std::swap(mesh->_indexStore[i + 1], mesh->_indexStore[i + 2]);
    mesh.name = @"Box";
    return mesh;
}

+ (BKMesh *)sphereMeshWithCenter:(simd_float3)center radius:(float)radius subdivisions:(NSUInteger)subdivisions
{
    subdivisions = MIN(subdivisions, (NSUInteger)7);
    // Regular icosahedron (12 corners, 20 faces) on the unit sphere.
    const float t = (1.0f + std::sqrt(5.0f)) / 2.0f;
    const float corners[12][3] = {
        {-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
        {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
        {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1},
    };
    std::vector<simd_float3> v;
    for (const auto &c : corners) v.push_back(simd_make_float3(c[0], c[1], c[2]));
    for (auto &p : v) p = simd_normalize(p);
    std::vector<uint32_t> f = {
        0, 11, 5,  0, 5, 1,  0, 1, 7,  0, 7, 10,  0, 10, 11,
        1, 5, 9,  5, 11, 4,  11, 10, 2,  10, 7, 6,  7, 1, 8,
        3, 9, 4,  3, 4, 2,  3, 2, 6,  3, 6, 8,  3, 8, 9,
        4, 9, 5,  2, 4, 11,  6, 2, 10,  8, 6, 7,  9, 8, 1,
    };
    // Each subdivision splits every triangle into four, pushing the new edge midpoints
    // out onto the sphere. Shared midpoints are reused so the surface stays closed.
    for (NSUInteger s = 0; s < subdivisions; s++) {
        std::unordered_map<uint64_t, uint32_t> midpoints;
        auto midpoint = [&](uint32_t a, uint32_t b) -> uint32_t {
            uint64_t key = ((uint64_t)std::min(a, b) << 32) | std::max(a, b);
            auto it = midpoints.find(key);
            if (it != midpoints.end()) return it->second;
            v.push_back(simd_normalize(v[a] + v[b]));
            uint32_t idx = (uint32_t)v.size() - 1;
            midpoints[key] = idx;
            return idx;
        };
        std::vector<uint32_t> next;
        next.reserve(f.size() * 4);
        for (size_t i = 0; i < f.size(); i += 3) {
            uint32_t a = f[i], b = f[i + 1], c = f[i + 2];
            uint32_t ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a);
            uint32_t tris[12] = {a, ab, ca,  b, bc, ab,  c, ca, bc,  ab, bc, ca};
            next.insert(next.end(), tris, tris + 12);
        }
        f.swap(next);
    }
    // On a unit sphere the normal is the point itself.
    std::vector<simd_float3> normals = v;
    for (auto &p : v) p = center + p * radius;
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:v.data() vertexCount:v.size() indices:f.data() indexCount:f.size()
                                            normals:normals.data() colors:NULL error:NULL];
    if (mesh.enclosedVolume < 0) {
        for (size_t i = 0; i + 2 < mesh->_indexStore.size(); i += 3) std::swap(mesh->_indexStore[i + 1], mesh->_indexStore[i + 2]);
        if (radius < 0) for (auto &n : mesh->_normalStore) n = -n;
    }
    mesh.name = @"Sphere";
    return mesh;
}

@end
