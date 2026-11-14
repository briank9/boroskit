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

// --- Added 2026-11-14 (ROI volume window): face culling, textures, points -----------------
// Original BorosKit code written for this project; contains no third-party code.
// PORTING NOTES: the rules (which side is "front", how a texture is looked up and combined
// with the lit colour, how big a point is) are written once in plain C in BKMeshDrawCore.h
// with CPU reference functions; a Vulkan backend follows that file. Texture pixels are plain
// RGBA8 rows (row 0 = texture coordinate t = 0); texture coordinates are a tightly packed
// float x2 array per vertex (8-byte stride, std430 vec2-compatible).

// Which side of each triangle is left out (same values as BKMeshCullNone/Back/Front in
// BKMeshDrawCore.h). The front side is the one whose corners run anticlockwise on screen
// (OpenGL / VTK rule). Why: VTK scenes copied into Metal (e.g. the ROI volume window) use
// back-face culling, which changes the picture of open or inside-out surfaces.
typedef NS_ENUM(NSInteger, BKMeshFaceCulling) {
    BKMeshFaceCullingNone = 0,    // both sides drawn (default)
    BKMeshFaceCullingBack = 1,    // back sides not drawn
    BKMeshFaceCullingFront = 2,   // front sides not drawn
};

// A picture laid onto a surface (RGBA, 8 bits per channel). Why: VTK's textured surfaces (the
// ROI volume window's "Textured" display) must look the same when Metal draws them.
@interface BKMeshTexture : NSObject

// `pixels`: width x height texels with `components` bytes each (1 = grey, 2 = grey + alpha,
// 3 = RGB, 4 = RGBA - the OpenGL / VTK meaning), rows one after another, row 0 at texture
// coordinate t = 0 (VTK image row 0). Returns nil for an empty picture or another component count.
- (nullable instancetype)initWithPixels:(const uint8_t *)pixels components:(NSUInteger)components
                                  width:(NSUInteger)width height:(NSUInteger)height;

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSData *rgba8Data;          // width * height * 4 bytes, row 0 = t = 0
@property (nonatomic, readonly, getter=isOpaque) BOOL opaque;   // YES when every alpha is 255

// YES (default) = blend the 4 nearest texels (VTK InterpolateOn); NO = nearest texel.
@property (nonatomic) BOOL interpolate;
// YES (default) = the picture repeats outside 0..1 (VTK RepeatOn); NO = clamp to the edge.
@property (nonatomic) BOOL repeat;

@end
// --- end of the 2026-11-14 types ----------------------------------------------------------

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

// --- Added 2026-11-14 ------------------------------------------------------------------
// Which side of the triangles is left out. Default BKMeshFaceCullingNone (both sides drawn).
@property (nonatomic) BKMeshFaceCulling faceCulling;

// Texture coordinates (s, t), one per mesh vertex, in texture units (0..1 = one copy of the
// picture). NULL / 0 removes them. Copied. Used only when `texture` is set too and the count
// equals the mesh's vertex count (otherwise the object is drawn untextured, exactly as VTK
// does for a textured actor without texture coordinates).
- (void)setTextureCoordinates:(nullable const simd_float2 *)coordinates count:(NSUInteger)count;
@property (nonatomic, readonly) NSUInteger textureCoordinateCount;
@property (nonatomic, readonly, nullable) const simd_float2 *textureCoordinates;

// The picture laid onto the surface (nil = none, the default). Its colour multiplies the lit
// surface colour, its alpha multiplies the opacity (a picture with transparent texels makes
// the object see-through).
@property (nonatomic, strong, nullable) BKMeshTexture *texture;

// YES when the object is drawn with its texture (texture set and one coordinate per vertex).
@property (nonatomic, readonly, getter=isTextured) BOOL textured;

@end

// Added 2026-11-14: points drawn as small squares of a fixed size in PIXELS (like VTK's
// "points" representation and vertex cells, glPointSize), depth-tested like everything else.
// Why: a VTK scene may show an object as its points; Metal must draw them, not skip them.
@interface BKPointObject : NSObject

// `points`: `count` positions in mm (before `transform`). Copied. NULL = no points.
- (instancetype)initWithPoints:(nullable const simd_float3 *)points count:(NSUInteger)count;
- (void)setPoints:(nullable const simd_float3 *)points count:(NSUInteger)count;
@property (nonatomic, readonly) NSUInteger pointCount;
@property (nonatomic, readonly) const simd_float3 *points;

@property (nonatomic) simd_float3 color;     // RGB 0..1, default white
@property (nonatomic) float opacity;         // default 1
@property (nonatomic) CGFloat pointSize;     // side of the square in pixels of the output image, default 1
@property (nonatomic, getter=isVisible) BOOL visible;   // default YES
@property (nonatomic) simd_float4x4 transform;          // placement, like BKMeshObject (default identity)

// Bounding box of the placed points in patient mm.
- (void)getPatientBoundsMin:(simd_float3 *)min max:(simd_float3 *)max;

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

// Added 2026-11-14: point sets to draw with the objects (solid ones with the solid lines,
// see-through ones in the see-through pass). Default empty.
@property (nonatomic, copy) NSArray<BKPointObject *> *pointObjects;

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

// --- Picking ---------------------------------------------------------------------------
// What 3D point (patient mm) is under a pixel: renders the scene at width x height (with the
// current camera and viewport), reads the ray distance of the nearest SOLID surface or line
// at pixel (x, y) (pixels from the top-left, fractions allowed) and turns it back into a
// point with the same camera maths as the drawing. Returns NO when nothing solid is under
// the pixel (or on GPU failure).
// Why: placing points / centring on a click needs "where is the bone under the mouse".
// The old VTK views read OpenGL's depth buffer for that; Metal gives the exact distance.
- (BOOL)pickPatientPoint:(simd_float3 *)point atPixelX:(double)x y:(double)y
                   width:(NSUInteger)width height:(NSUInteger)height
                   error:(NSError * _Nullable * _Nullable)error;

// For tests: the uniform block size as the GPU / CPU compilers see it (must match).
- (NSUInteger)gpuUniformBlockSize;
+ (NSUInteger)cpuUniformBlockSize;

@end

// The pixel -> point maths used by -pickPatientPoint:..., as a plain C function (no GPU, so
// a Vulkan backend can share it). (ndcX, ndcY): position in the drawing area from -1 (left /
// bottom) to +1 (right / top); rayDistance: as written by the renderer (orthographic: along
// the view direction from the image plane; perspective: from the eye along the pixel's ray).
// halfWidth / halfHeight: orthographic = half the image size in mm; perspective = tan of the
// half angles. right/up/forward: the orthonormal camera frame; position: image-plane centre
// (orthographic) or eye (perspective).
simd_float3 BKMeshUnprojectPixel(BKProjection projection, simd_float3 position, simd_float3 right,
                                 simd_float3 up, simd_float3 forward, float halfWidth, float halfHeight,
                                 float ndcX, float ndcY, float rayDistance);

NS_ASSUME_NONNULL_END
