// BorosKitMeshRender: BKMeshObject and BKMeshRenderer
//
// What it is: draws surface meshes (BKMesh: bone surfaces, intraoral scans, implants,
// surgical guides) on the GPU with Apple's Metal. It replaces the OpenGL drawing of
// the old VTK surface views in Horos, so it works on Mac and iPad alike.
//
// Same camera as the volume: the camera settings mean exactly what they mean for
// BKVolumeRenderer (patient millimetres; orthographic = centre of the image plane +
// image size in mm; perspective = eye + vertical angle), and -setCameraFromVolumeCamera:
// / -copyCameraFromVolumeRenderer: take them over directly. So a mesh made from the CT
// (or registered to it) appears on exactly the same pixels as the bone in the volume
// picture. The tests check this pixel-for-pixel from the standard views.
//
// Lighting: like the volume picture: a light at the viewer ("headlight") plus ambient,
// with the same default strengths (0.2 ambient, 0.8 diffuse, 0.2 specular, power 10).
//
// Transparency: opaque objects are drawn first with depth testing; see-through objects
// (opacity < 1) are drawn afterwards from the farthest to the nearest object, without
// hiding what lies behind them. (Triangles WITHIN one see-through object are not sorted,
// so a strongly folded see-through mesh can look slightly wrong; fine for guides/implants.)
//
// Combining with the volume (prepared, not done yet): every render can also output the
// "ray distance": for each pixel, how far (mm) along the viewing ray the nearest OPAQUE
// mesh surface is, measured exactly like the volume ray caster's own ray parameter
// (orthographic: signed distance from the image plane along the view direction;
// perspective: distance from the eye). The planned next step is for BKVolumeRenderer to
// accept that texture and stop each ray at the mesh, then lay its colour over the mesh
// image, giving correct "implant inside the bone" pictures. Until then, -encodeRender...
// with `clear:NO` can draw meshes OVER an existing volume image (no hiding by bone).
//
// Coordinates: patient (DICOM) millimetres, like the rest of BorosKit.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "BKMesh.h"
#import "BKVolumeRenderer.h"
#import "BKVolumeCamera.h"

NS_ASSUME_NONNULL_BEGIN

// One thing to draw: a mesh plus how it looks and where it is placed.
@interface BKMeshObject : NSObject

- (instancetype)initWithMesh:(BKMesh *)mesh;

// The shape. The renderer re-uploads it to the GPU automatically when it changes
// (it watches BKMesh.version), so editing the mesh in place is fine.
@property (nonatomic, strong) BKMesh *mesh;

// Colour (RGB 0..1). Default: a light bone colour. Multiplied with the mesh's vertex
// colours when those are used.
@property (nonatomic) simd_float3 color;

// 1 = solid (default), 0 = invisible, in between = see-through.
@property (nonatomic) float opacity;

// NO hides the object without removing it. Default YES.
@property (nonatomic, getter=isVisible) BOOL visible;

// YES (default) = use the mesh's own per-vertex colours if it has any (coloured
// intraoral scans); NO = plain `color`.
@property (nonatomic) BOOL useVertexColors;

// Placement of the object: mesh coordinates -> patient mm (simd convention,
// point' = M * point). Default identity. Why separate from the mesh: moving an implant
// while planning only changes this matrix, nothing is re-uploaded.
@property (nonatomic) simd_float4x4 transform;

// Bounding box of the placed object in patient mm (the mesh's box corners pushed
// through `transform`).
- (void)getPatientBoundsMin:(simd_float3 *)min max:(simd_float3 *)max;

// --- Own lighting (optional) ----------------------------------------------------------
// Why: in a scene copied from another program (e.g. VTK), each object has its own
// material: a shiny bone surface next to a matt orientation cube. NO (default) = use the
// renderer's ambient/diffuse/specular/specularPower; YES = use the four values below.
@property (nonatomic) BOOL usesOwnMaterial;
@property (nonatomic) float ambient;        // default 0.2
@property (nonatomic) float diffuse;        // default 0.8
@property (nonatomic) float specular;       // default 0.2
@property (nonatomic) float specularPower;  // default 10

// NO = drawn in its plain colour without any lighting (labels, letters). Default YES.
@property (nonatomic, getter=isLit) BOOL lit;

@end

// Straight line segments drawn in 3D (outline boxes, wireframes, measurement lines).
// Why: an outline box around the scan, or a wireframe, is a set of lines, not a surface.
// Lines have a fixed width in PIXELS (they don't get thicker when you zoom in) and are
// hidden by surfaces in front of them, like everything else in the 3D scene.
@interface BKLineObject : NSObject

// `points` holds 2 points per segment (start, end), in mm; `count` = number of points
// (must be even; an odd last point is ignored).
- (instancetype)initWithPoints:(const simd_float3 *)points count:(NSUInteger)count;

// Replaces the segments (same layout as the initializer). Re-uploaded automatically.
- (void)setPoints:(const simd_float3 *)points count:(NSUInteger)count;
@property (nonatomic, readonly) NSUInteger segmentCount;
@property (nonatomic, readonly) const simd_float3 *points;   // 2 * segmentCount points

@property (nonatomic) simd_float3 color;     // RGB 0..1, default white
@property (nonatomic) float opacity;         // default 1
@property (nonatomic) CGFloat lineWidth;     // pixels of the output image, default 1
@property (nonatomic, getter=isVisible) BOOL visible;   // default YES
@property (nonatomic) simd_float4x4 transform;          // placement, like BKMeshObject (default identity)

// Bounding box of the placed segments in patient mm.
- (void)getPatientBoundsMin:(simd_float3 *)min max:(simd_float3 *)max;

@end

@interface BKMeshRenderer : NSObject

// Creates a renderer on `device` (nil = the system's default GPU) and compiles the
// shaders. Returns nil + error if there is no GPU or compiling fails.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device
                                  error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

// What to draw, in order (order only matters between see-through objects at the same
// distance).
@property (nonatomic, copy) NSArray<BKMeshObject *> *objects;

// Line segments to draw with the objects (solid ones with the solid objects, see-through
// ones after them). Default empty.
@property (nonatomic, copy) NSArray<BKLineObject *> *lineObjects;

// Part of the output image to draw into, in pixels, origin top-left (CGRectZero = the
// whole image, the default). Why: a small orientation cube in a corner of a 3D view is
// a second scene with its own camera drawn into a corner of the same picture. The camera
// aspect ratio given to -setCameraFromVolumeCamera:aspectRatio: should then be the
// viewport's width / height. Nothing outside the viewport is changed (except by `clear`).
@property (nonatomic) CGRect viewport;

// --- Camera: same meaning as BKVolumeRenderer's (patient mm) --------------------------
@property (nonatomic) BKProjection projection;
@property (nonatomic) N3Vector cameraPosition;   // ortho: image-plane centre; perspective: eye
@property (nonatomic) N3Vector cameraDirection;  // need not be unit length
@property (nonatomic) N3Vector cameraUp;         // made perpendicular to the direction
@property (nonatomic) CGFloat viewWidth;         // mm (orthographic)
@property (nonatomic) CGFloat viewHeight;        // mm (orthographic)
@property (nonatomic) CGFloat fieldOfView;       // degrees, vertical (perspective), default 30

// Takes over the interactive 3D camera (exactly what -[BKVolumeCamera applyToRenderer:
// aspectRatio:] gives the volume renderer). aspectRatio = image width / height.
- (void)setCameraFromVolumeCamera:(BKVolumeCamera *)camera aspectRatio:(CGFloat)aspectRatio;

// Takes over the camera of a volume renderer as it is set right now.
- (void)copyCameraFromVolumeRenderer:(BKVolumeRenderer *)volumeRenderer;

// --- Lighting (same defaults as the volume renderer) ---------------------------------
@property (nonatomic) float ambient;        // 0.2
@property (nonatomic) float diffuse;        // 0.8
@property (nonatomic) float specular;       // 0.2
@property (nonatomic) float specularPower;  // 10

// --- Rendering --------------------------------------------------------------------------
// Renders the objects into a new image (offscreen) and waits for the GPU.
// rgba8Data: colour premultiplied by opacity over a fully transparent background (so it
//   can be laid over anything); floatData: the ray distance (mm) of the nearest opaque
//   surface per pixel, +infinity where there is none (see "Combining with the volume").
// Returns nil + error if the size is zero or the GPU fails. No objects = empty image.
- (nullable BKRenderResult *)renderWithWidth:(NSUInteger)width
                                      height:(NSUInteger)height
                                       error:(NSError * _Nullable * _Nullable)error;

// Encodes the drawing into `colorTexture` without waiting (on-screen views; the caller
// commits the command buffer). clear = YES fills it with `clearColor` first (RGBA 0..1,
// premultiplied); NO draws on top of what is already there (e.g. a volume image).
// `rayDistanceTexture` (optional, MTLPixelFormatR32Float, same size, render-target
// usage) receives the ray distances; it is cleared to +infinity.
- (BOOL)encodeRenderToColorTexture:(id<MTLTexture>)colorTexture
                rayDistanceTexture:(nullable id<MTLTexture>)rayDistanceTexture
                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                             clear:(BOOL)clear
                        clearColor:(simd_float4)clearColor
                             error:(NSError * _Nullable * _Nullable)error;

// For tests: the uniform block size as the GPU / CPU compilers see it (must match).
- (NSUInteger)gpuUniformBlockSize;
+ (NSUInteger)cpuUniformBlockSize;

@end

NS_ASSUME_NONNULL_END
