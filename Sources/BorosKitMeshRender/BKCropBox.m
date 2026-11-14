// BorosKitMeshRender: BKCropBox - native cropping box (state + drawable objects).
// Original BorosKit code written for this project; contains no third-party code.
// See include/BKCropBox.h; the maths is in BKBoxWidgetMath.c and BKCropBoxCore.c (plain C).

#import "BKCropBox.h"
#import "BKMeshRenderer.h"
#import "BKMesh.h"
#include <math.h>

// What: a sphere of radius 1 around the origin (latitude/longitude grid), with outward normals.
// Why: the round handles; each handle object places and sizes it with its transform, so the
// mesh is built once and never re-uploaded while the box moves.
static BKMesh *BKCropBoxUnitSphere(void)
{
    enum { slices = 16, stacks = 10 };
    simd_float3 vertices[(slices + 1) * (stacks + 1)];
    uint32_t indices[slices * stacks * 6];
    NSUInteger v = 0, i = 0;
    for (int st = 0; st <= stacks; st++) {
        double phi = M_PI * st / stacks;                 // 0 at the top, pi at the bottom
        for (int sl = 0; sl <= slices; sl++) {
            double theta = 2.0 * M_PI * sl / slices;
            vertices[v++] = simd_make_float3((float)(sin(phi) * cos(theta)), (float)(sin(phi) * sin(theta)), (float)cos(phi));
        }
    }
    for (int st = 0; st < stacks; st++) {
        for (int sl = 0; sl < slices; sl++) {
            uint32_t a = (uint32_t)(st * (slices + 1) + sl), b = a + slices + 1;
            // Two triangles per grid cell, anticlockwise seen from outside.
            indices[i++] = a; indices[i++] = b; indices[i++] = a + 1;
            indices[i++] = a + 1; indices[i++] = b; indices[i++] = b + 1;
        }
    }
    // On a unit sphere the outward normal of a point is the point itself.
    return [[BKMesh alloc] initWithVertices:vertices vertexCount:v indices:indices indexCount:i
                                    normals:vertices colors:NULL error:NULL];
}

// What: uniform scale by s followed by a move to `centre` (simd convention, p' = M * p).
static simd_float4x4 BKCropBoxPlacement(simd_double3 centre, double s)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = (float)s;
    m.columns[1].y = (float)s;
    m.columns[2].z = (float)s;
    m.columns[3] = simd_make_float4((float)centre.x, (float)centre.y, (float)centre.z, 1);
    return m;
}

@implementation BKCropBox
{
    BKOrientedBox _box;
    BOOL _cropsVolume;
    BKCropBoxDrag _drag;
    BKLineObject *_outline;
    NSArray<BKMeshObject *> *_handles;   // 7: faces -X, +X, -Y, +Y, -Z, +Z, then the centre
    BKMeshObject *_face;                 // the highlighted face (rebuilt while dragged)
    NSArray *_drawObjects;
}

// What: a hidden, non-cropping box at defaultBox, with the classic window's colours.
- (instancetype)initWithDefaultBox:(BKOrientedBox)defaultBox minimumEdge:(double)minimumEdge
{
    if ((self = [super init])) {
        _defaultBox = defaultBox;
        _box = defaultBox;
        _minimumEdge = minimumEdge;
        _drag.mode = BKCropDragNone;
        _drag.part = _drag.highlightHandle = _drag.highlightFace = -1;
        _worldScale = 1.0;
        _handleRadiusPoints = 5.0;
        _lineWidth = 1.0;
        _outlineColor = simd_make_float3(1, 1, 1);
        _selectedOutlineColor = simd_make_float3(0, 1, 0);
        _handleColor = simd_make_float3(0, 1, 0);
        _selectedHandleColor = simd_make_float3(1, 0, 0);
        _selectedFaceColor = simd_make_float3(1, 1, 0);
        _faceOpacity = 0.25f;

        _outline = [[BKLineObject alloc] init];   // no segments until the first update
        _outline.visible = NO;
        BKMesh *sphere = BKCropBoxUnitSphere();
        NSMutableArray *handles = [NSMutableArray array];
        for (int h = 0; h < BKBoxHandleCount; h++) {
            BKMeshObject *o = [[BKMeshObject alloc] initWithMesh:sphere];
            o.useVertexColors = NO;
            o.visible = NO;
            [handles addObject:o];
        }
        _handles = [handles copy];
        _face = [[BKMeshObject alloc] initWithMesh:[[BKMesh alloc] init]];
        _face.useVertexColors = NO;
        _face.lit = NO;
        _face.visible = NO;
        NSMutableArray *all = [NSMutableArray arrayWithObject:_outline];
        [all addObjectsFromArray:_handles];
        [all addObject:_face];
        _drawObjects = [all copy];
    }
    return self;
}

- (BKOrientedBox)box { return _box; }
- (BOOL)cropsVolume { return _cropsVolume; }
- (NSArray *)drawObjects { return _drawObjects; }
- (BKCropBoxDrag)drag { return _drag; }
- (BOOL)isDragging { return _drag.mode != BKCropDragNone; }

// What: back to the default box, cropping nothing. Why: a new volume / "reset" (the classic
// widget's PlaceWidget).
- (void)resetToDefaultBox
{
    _box = _defaultBox;
    _cropsVolume = NO;
}

// What: takes a box and whether it crops (restoring a saved state or adopting another keeper's box).
- (void)setBox:(BKOrientedBox)box cropsVolume:(BOOL)cropsVolume
{
    _box = box;
    _cropsVolume = cropsVolume;
}

// What: mouse-down; the decision (what was grabbed, which drag) is BKCropBoxBeginDrag's (plain C).
- (BOOL)beginDragAtViewX:(double)x yDown:(double)yDown button:(int32_t)button shift:(BOOL)shift
                  camera:(BKCameraFrame)camera viewWidth:(double)viewWidth viewHeight:(double)viewHeight
               cutPlanes:(const simd_float4 *)cutPlanes count:(NSUInteger)cutPlaneCount
{
    if (!_visible) return NO;
    BKCropBoxDrag d;
    uint32_t n = (uint32_t)MIN(cutPlaneCount, (NSUInteger)BK_CROP_MAX_CUT_PLANES);
    if (!BKCropBoxBeginDrag(_box, camera, viewWidth, viewHeight, x, yDown, button, shift, _handleRadiusPoints + 2.0,
                            cutPlanes ? (const float *)cutPlanes : NULL, cutPlanes ? n : 0, &d))
        return NO;
    _drag = d;
    return YES;
}

// What: one mouse move of a drag (BKCropBoxContinueDrag, plain C). A changed box crops.
- (BOOL)continueDragByViewX:(double)dx yDown:(double)dyDown camera:(BKCameraFrame)camera viewHeight:(double)viewHeight
{
    if (_drag.mode == BKCropDragNone) return NO;
    if (!BKCropBoxContinueDrag(&_box, &_drag, camera, viewHeight, dx, dyDown, _minimumEdge)) return NO;
    _cropsVolume = YES;
    return YES;
}

// What: mouse-up: no drag, no highlights.
- (void)endDrag
{
    _drag.mode = BKCropDragNone;
    _drag.part = _drag.highlightHandle = _drag.highlightFace = -1;
    _drag.highlightOutline = 0;
}

- (NSString *)dragDescription
{
    switch (_drag.mode) {
        case BKCropDragMoveFace: return @"face move";
        case BKCropDragTranslate: return @"move";
        case BKCropDragRotate: return @"turn";
        case BKCropDragScale: return @"resize";
        default: return nil;
    }
}

// What: places / shapes the drawable objects for this camera: the edges (cut by the slab) in
// the normal or "selected" colour, each handle where it is (hidden when cut away) at a radius
// that looks handleRadiusPoints big, the grabbed handle red, the grabbed face as a see-through
// yellow polygon (cut by the slab). Everything hidden when the box is.
- (void)updateDrawingWithCamera:(BKCameraFrame)camera viewHeight:(double)viewHeight
                      cutPlanes:(const simd_float4 *)cutPlanes count:(NSUInteger)cutPlaneCount
{
    const float *cut = cutPlanes ? (const float *)cutPlanes : NULL;
    uint32_t cutCount = cut ? (uint32_t)MIN(cutPlaneCount, (NSUInteger)BK_CROP_MAX_CUT_PLANES) : 0;
    simd_float4x4 world = BKCropBoxPlacement(simd_make_double3(0, 0, 0), _worldScale);

    // Edges.
    simd_float3 points[24];
    uint32_t n = _visible ? BKCropBoxOutline(_box, cut, cutCount, points) : 0;
    [_outline setPoints:points count:n];
    _outline.transform = world;
    _outline.lineWidth = _lineWidth;
    _outline.color = _drag.highlightOutline ? _selectedOutlineColor : _outlineColor;
    _outline.visible = n > 0;

    // Handles.
    for (int h = 0; h < BKBoxHandleCount; h++) {
        BKMeshObject *o = _handles[h];
        simd_double3 p = BKBoxHandlePosition(_box, h);
        BOOL shown = _visible && BKCutPlanesKeepPoint(cut, cutCount, p) && viewHeight > 0;
        o.visible = shown;
        if (!shown) continue;
        double r = BKCropBoxScreenRadius(camera, viewHeight, p, _handleRadiusPoints);
        o.transform = BKCropBoxPlacement(p * _worldScale, r * _worldScale);
        o.color = (h == _drag.highlightHandle) ? _selectedHandleColor : _handleColor;
    }

    // Highlighted face: a fan of triangles over the (cut) convex polygon.
    simd_float3 poly[BK_CROP_FACE_MAX_POINTS];
    uint32_t corners = (_visible && _drag.highlightFace >= 0) ? BKCropBoxFacePolygon(_box, _drag.highlightFace, cut, cutCount, poly) : 0;
    if (corners >= 3) {
        uint32_t indices[3 * (BK_CROP_FACE_MAX_POINTS - 2)];
        uint32_t k = 0;
        for (uint32_t i = 1; i + 1 < corners; i++) { indices[k++] = 0; indices[k++] = i; indices[k++] = i + 1; }
        BKMesh *mesh = [[BKMesh alloc] initWithVertices:poly vertexCount:corners indices:indices indexCount:k
                                                normals:NULL colors:NULL error:NULL];
        if (mesh) _face.mesh = mesh;
        _face.visible = mesh != nil;
    } else {
        _face.visible = NO;
    }
    _face.transform = world;
    _face.color = _selectedFaceColor;
    _face.opacity = _faceOpacity;
}

// What: the 6 face planes (cut outside the box) in the GPU packing, when the box crops.
- (NSUInteger)getClipPlanes:(simd_float4 *)out
{
    if (!_cropsVolume || out == NULL) return 0;
    float packed[24];
    BKBoxClipPlanes(_box, packed);
    for (int f = 0; f < 6; f++) out[f] = simd_make_float4(packed[4 * f], packed[4 * f + 1], packed[4 * f + 2], packed[4 * f + 3]);
    return 6;
}

@end
