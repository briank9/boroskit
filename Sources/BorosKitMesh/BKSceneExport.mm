// BorosKitMesh: BKSceneExport implementation (thin wrapper around BKSceneExportCore).
// Original BorosKit code written for this project; contains no third-party code.

#import "BKSceneExport.h"
#include "BKSceneExportCore.h"

using namespace boroskit::sceneexport;

BKSceneMaterial BKSceneMaterialDefault(void)
{
    BKSceneMaterial m;
    m.color = simd_make_float3(0.95f, 0.9f, 0.8f);
    m.opacity = 1; m.ambient = 0.2f; m.diffuse = 0.8f; m.specular = 0.2f; m.specularPower = 10;
    m.lit = YES; m.useVertexColors = YES;
    return m;
}

// One stored surface or line set (the mesh is kept, the line points are copied).
@interface BKSceneExportItem : NSObject
@property (nonatomic, strong) BKMesh *mesh;
@property (nonatomic, strong) NSData *linePoints;   // packed float x,y,z
@property (nonatomic) simd_float4x4 transform;
@property (nonatomic) BKSceneMaterial material;
@property (nonatomic) float lineWidth;
@property (nonatomic, copy) NSString *name;
@end
@implementation BKSceneExportItem
@end

// Copies a simd matrix (column-major floats) into the core's 16 doubles.
static void BKCopyMatrix(simd_float4x4 m, double out[16])
{
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) out[c * 4 + r] = m.columns[c][r];
}

// The core calls this between blocks; it forwards to the Objective-C block.
static bool BKSceneProgress(double fraction, void *context)
{
    BKMeshProgressHandler handler = (__bridge BKMeshProgressHandler)context;
    return handler(fraction);
}

@implementation BKSceneExport {
    NSMutableArray<BKSceneExportItem *> *_meshes, *_lines;
    Camera _camera;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _meshes = [NSMutableArray array]; _lines = [NSMutableArray array];
        _imageWidth = 640; _imageHeight = 480; _headlight = YES; _headlightIntensity = 1;
    }
    return self;
}

- (void)addMesh:(BKMesh *)mesh transform:(simd_float4x4)transform material:(BKSceneMaterial)material name:(NSString *)name
{
    BKSceneExportItem *item = [BKSceneExportItem new];
    item.mesh = mesh; item.transform = transform; item.material = material; item.name = name ?: mesh.name ?: @"";
    [_meshes addObject:item];
}

- (void)addLineSegments:(const simd_float3 *)points count:(NSUInteger)count transform:(simd_float4x4)transform
                  color:(simd_float3)color opacity:(float)opacity lineWidth:(float)lineWidth name:(NSString *)name
{
    NSUInteger n = count / 2 * 2;
    NSMutableData *packed = [NSMutableData dataWithLength:n * 3 * sizeof(float)];
    float *p = (float *)packed.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) { p[3 * i] = points[i].x; p[3 * i + 1] = points[i].y; p[3 * i + 2] = points[i].z; }
    BKSceneExportItem *item = [BKSceneExportItem new];
    BKSceneMaterial m = BKSceneMaterialDefault();
    m.color = color; m.opacity = opacity;
    item.linePoints = packed; item.transform = transform; item.material = m; item.lineWidth = lineWidth; item.name = name ?: @"";
    [_lines addObject:item];
}

- (void)removeAllItems { [_meshes removeAllObjects]; [_lines removeAllObjects]; }
- (NSUInteger)meshCount { return _meshes.count; }
- (NSUInteger)lineSetCount { return _lines.count; }

- (void)setCamera:(simd_double3)position focal:(simd_double3)focal up:(simd_double3)up
{
    _camera.present = true;
    for (int i = 0; i < 3; i++) { _camera.position[i] = position[i]; _camera.focalPoint[i] = focal[i]; _camera.viewUp[i] = up[i]; }
}
- (void)setPerspectiveCameraWithPosition:(simd_double3)position focalPoint:(simd_double3)focalPoint viewUp:(simd_double3)viewUp viewAngle:(double)degrees
{
    [self setCamera:position focal:focalPoint up:viewUp];
    _camera.projection = Projection::Perspective; _camera.viewAngle = degrees;
}
- (void)setParallelCameraWithPosition:(simd_double3)position focalPoint:(simd_double3)focalPoint viewUp:(simd_double3)viewUp parallelScale:(double)halfHeightMM
{
    [self setCamera:position focal:focalPoint up:viewUp];
    _camera.projection = Projection::Parallel; _camera.parallelScale = halfHeightMM;
}
- (void)removeCamera { _camera.present = false; }
- (BOOL)hasCamera { return _camera.present; }
- (void)setBackgroundColor:(simd_float3)backgroundColor { _backgroundColor = backgroundColor; _hasBackground = YES; }

+ (BKSceneFileFormat)formatForPathExtension:(NSString *)extension
{
    NSString *e = extension.lowercaseString;
    if ([e isEqualToString:@"obj"]) return BKSceneFileFormatOBJ;
    if ([e isEqualToString:@"wrl"] || [e isEqualToString:@"vrml"]) return BKSceneFileFormatVRML;
    if ([e isEqualToString:@"iv"]) return BKSceneFileFormatInventor;
    if ([e isEqualToString:@"rib"]) return BKSceneFileFormatRIB;
    return BKSceneFileFormatUnknown;
}

+ (NSURL *)materialLibraryURLForOBJURL:(NSURL *)url
{
    return [NSURL fileURLWithPath:@(MaterialPathForOBJ(url.path.fileSystemRepresentation).c_str())];
}

- (BOOL)writeToURL:(NSURL *)url format:(BKSceneFileFormat)format error:(NSError **)error
{
    if (format == BKSceneFileFormatUnknown) format = [BKSceneExport formatForPathExtension:url.pathExtension];
    Format f;
    switch (format) {
        case BKSceneFileFormatOBJ: f = Format::OBJ; break;
        case BKSceneFileFormatVRML: f = Format::VRML2; break;
        case BKSceneFileFormatInventor: f = Format::Inventor; break;
        case BKSceneFileFormatRIB: f = Format::RIB; break;
        default:
            if (error) *error = [NSError errorWithDomain:BKMeshErrorDomain code:BKMeshErrorUnknownFormat
                                                userInfo:@{NSLocalizedDescriptionKey: @"Please choose a scene format (OBJ, VRML, Inventor or RIB)."}];
            return NO;
    }
    // Fill the core's scene straight from the meshes' own arrays (no copies).
    // simd_float3 is 16 bytes (padded), so positions/normals are repacked to x,y,z.
    Scene scene;
    std::vector<std::vector<float>> packed;   // keeps repacked arrays alive during the write
    packed.reserve(_meshes.count * 2);
    for (BKSceneExportItem *item in _meshes) {
        BKMesh *mesh = item.mesh;
        MeshItem m;
        m.name = item.name.UTF8String ?: "";
        NSUInteger n = mesh.vertexCount;
        packed.emplace_back(n * 3);
        for (NSUInteger i = 0; i < n; i++) { simd_float3 v = mesh.vertices[i]; packed.back()[3 * i] = v.x; packed.back()[3 * i + 1] = v.y; packed.back()[3 * i + 2] = v.z; }
        m.positions = packed.back().data();
        m.vertexCount = n;
        m.indices = mesh.indices; m.triangleCount = mesh.triangleCount;
        if (mesh.normals) {
            packed.emplace_back(n * 3);
            for (NSUInteger i = 0; i < n; i++) { simd_float3 v = mesh.normals[i]; packed.back()[3 * i] = v.x; packed.back()[3 * i + 1] = v.y; packed.back()[3 * i + 2] = v.z; }
            m.normals = packed.back().data();
        }
        BKSceneMaterial mat = item.material;
        if (mat.useVertexColors && mesh.colors) m.colors = (const float *)mesh.colors;   // simd_float4 = 4 packed floats
        BKCopyMatrix(item.transform, m.matrix);
        m.color[0] = mat.color.x; m.color[1] = mat.color.y; m.color[2] = mat.color.z;
        m.opacity = mat.opacity; m.ambient = mat.ambient; m.diffuse = mat.diffuse;
        m.specular = mat.specular; m.specularPower = mat.specularPower; m.lit = mat.lit;
        scene.meshes.push_back(m);
    }
    for (BKSceneExportItem *item in _lines) {
        LineItem l;
        l.name = item.name.UTF8String ?: "";
        l.points = (const float *)item.linePoints.bytes;
        l.segmentCount = item.linePoints.length / (6 * sizeof(float));
        BKCopyMatrix(item.transform, l.matrix);
        BKSceneMaterial mat = item.material;
        l.color[0] = mat.color.x; l.color[1] = mat.color.y; l.color[2] = mat.color.z;
        l.opacity = mat.opacity; l.width = item.lineWidth;
        scene.lines.push_back(l);
    }
    scene.camera = _camera;
    scene.hasBackground = _hasBackground;
    scene.background[0] = _backgroundColor.x; scene.background[1] = _backgroundColor.y; scene.background[2] = _backgroundColor.z;
    scene.headlight = _headlight; scene.headlightIntensity = _headlightIntensity;
    scene.imageWidth = (unsigned)MAX(1, _imageWidth); scene.imageHeight = (unsigned)MAX(1, _imageHeight);
    scene.title = _title.UTF8String ?: "";

    BKMeshProgressHandler handler = self.progressHandler;
    Result r = WriteScene(scene, f, url.path.fileSystemRepresentation, handler ? BKSceneProgress : nullptr, (__bridge void *)handler);
    if (r.ok()) return YES;
    if (error) {
        NSString *message = @(r.message.c_str());
        if (r.error == ErrorKind::Cancelled)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey: message}];
        else
            *error = [NSError errorWithDomain:BKMeshErrorDomain
                                         code:(r.error == ErrorKind::InvalidScene ? BKMeshErrorInvalidGeometry : BKMeshErrorUnreadableFile)
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

@end
