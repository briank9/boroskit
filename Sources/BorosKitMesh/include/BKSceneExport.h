// BorosKitMesh: BKSceneExport
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: saves a whole 3D scene (several surfaces, each with its placement and
// material, plus line sets, camera, background and head light) as OBJ+MTL, VRML 2.0,
// Open Inventor 2.1 or RenderMan RIB. Everything is written in world (patient) mm.
// Why: replaces the VTK exporters of the Surface Rendering window's Export menu, so
// the export matches what Metal draws. The work is done by the plain C++ core
// (BKSceneExportCore.h); this class only collects the scene.
// Meshes are NOT copied: do not change them while a write is running.

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "BKMesh.h"
#import "BKMeshProcessing.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKSceneFileFormat) {
    BKSceneFileFormatUnknown = 0,
    BKSceneFileFormatOBJ,       // .obj + .mtl next to it
    BKSceneFileFormatVRML,      // .wrl (VRML 2.0)
    BKSceneFileFormatInventor,  // .iv  (Open Inventor 2.1 ASCII)
    BKSceneFileFormatRIB,       // .rib (RenderMan)
};

// How a surface looks (same meaning as BKMeshObject's material).
typedef struct {
    simd_float3 color;      // RGB 0..1 (vertex colours are multiplied by it, as drawn)
    float opacity;          // 1 = solid
    float ambient, diffuse, specular, specularPower;
    BOOL lit;               // NO = plain colour, no lighting
    BOOL useVertexColors;   // YES = export the mesh's per-vertex colours if it has any
} BKSceneMaterial;

// Defaults: bone-white, solid, 0.2 / 0.8 / 0.2 / 10, lit, vertex colours used.
FOUNDATION_EXPORT BKSceneMaterial BKSceneMaterialDefault(void);

@interface BKSceneExport : NSObject

- (void)addMesh:(BKMesh *)mesh transform:(simd_float4x4)transform material:(BKSceneMaterial)material name:(nullable NSString *)name;
// `points`: 2 per segment (start, end), mm; `count` = number of points.
- (void)addLineSegments:(const simd_float3 *)points count:(NSUInteger)count transform:(simd_float4x4)transform
                  color:(simd_float3)color opacity:(float)opacity lineWidth:(float)lineWidth name:(nullable NSString *)name;
- (void)removeAllItems;
@property (nonatomic, readonly) NSUInteger meshCount;
@property (nonatomic, readonly) NSUInteger lineSetCount;

// Camera (VTK style, patient mm). Without a camera, VRML/Inventor let the viewer choose
// and RIB uses a front view fitted to the scene.
- (void)setPerspectiveCameraWithPosition:(simd_double3)position focalPoint:(simd_double3)focalPoint
                                  viewUp:(simd_double3)viewUp viewAngle:(double)degrees;
- (void)setParallelCameraWithPosition:(simd_double3)position focalPoint:(simd_double3)focalPoint
                               viewUp:(simd_double3)viewUp parallelScale:(double)halfHeightMM;
- (void)removeCamera;
@property (nonatomic, readonly) BOOL hasCamera;

@property (nonatomic) NSUInteger imageWidth;    // default 640 (aspect ratio; RIB image size)
@property (nonatomic) NSUInteger imageHeight;   // default 480
@property (nonatomic) BOOL hasBackground;       // default NO
@property (nonatomic) simd_float3 backgroundColor;  // setting it sets hasBackground = YES
@property (nonatomic) BOOL headlight;           // default YES
@property (nonatomic) float headlightIntensity; // default 1
@property (nonatomic, copy, nullable) NSString *title;
// Called on the calling thread; return NO to cancel (error NSCocoaErrorDomain/NSUserCancelledError).
@property (nonatomic, copy, nullable) BKMeshProgressHandler progressHandler;

+ (BKSceneFileFormat)formatForPathExtension:(NSString *)extension;   // obj, wrl, vrml, iv, rib
+ (NSURL *)materialLibraryURLForOBJURL:(NSURL *)url;                  // where the .mtl goes

// Writes the scene (atomically). Unknown format = from the extension.
// Errors: BKMeshErrorDomain (InvalidGeometry / UnreadableFile / UnknownFormat) or cancel.
- (BOOL)writeToURL:(NSURL *)url format:(BKSceneFileFormat)format error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
