// BorosKitMeshRender: BKMeshGeometryLayer - meshes, lines and points drawn INSIDE a 3D volume.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Plain language: give this object the things to show with the scan (e.g. the red 3D point
// balls) and hand it to a BKVolumeScene (scene.geometryLayer). On every frame the scene asks it to
// draw them with the volume's own camera into a colour picture and a "how far along each ray"
// picture; the volume ray caster then stops at them. Result: bone in front hides an object, the
// object hides bone behind it, exactly like the classic VTK 3D window - and the objects can never
// lag behind the volume, since both use the same camera in the same frame.
//
// Coordinates: patient millimetres (the volume's world). Objects in another unit (e.g. VTK's
// world = mm x factor) are placed with their own `transform` (scale by 1/factor).
// Opaque objects hide / are hidden correctly. See-through objects are laid behind everything
// the ray passed (fine for highlights; a see-through object in front of bone is not supported).
//
// PORTING NOTES (Vulkan): all drawing goes through BKMeshRenderer (its own porting notes apply);
// this class only keeps the two output images (RGBA8 colour, R32F ray distance) and the lists.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "BKMeshRenderer.h"
#import "BKVolumeGeometryLayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface BKMeshGeometryLayer : NSObject <BKVolumeGeometryLayer>

// Creates the layer on `device` (must be the volume renderer's device). nil + error if the mesh
// renderer can't be made.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError * _Nullable * _Nullable)error;

// What to draw (patient mm, see the header comment). Default empty. Set them from the main
// thread; the next frame uses them (call the view's -setNeedsRedraw after a change).
@property (nonatomic, copy) NSArray<BKMeshObject *> *objects;
@property (nonatomic, copy) NSArray<BKLineObject *> *lineObjects;
@property (nonatomic, copy) NSArray<BKPointObject *> *pointObjects;

// YES when there is at least one visible object to draw.
@property (nonatomic, readonly) BOOL hasVisibleObjects;

// The mesh renderer used (lighting: ambient / diffuse / specular for objects without their own
// material).
@property (nonatomic, readonly) BKMeshRenderer *renderer;

@end

NS_ASSUME_NONNULL_END
