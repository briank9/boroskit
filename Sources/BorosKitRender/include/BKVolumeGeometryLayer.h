// BorosKitRender: BKVolumeGeometryLayer - opaque objects drawn INSIDE the 3D volume picture.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Plain language: the 3D window can show objects together with the scan (e.g. the red 3D point
// balls). They must be hidden by bone in front of them and hide the bone behind them, exactly
// like in the classic VTK window. To do that, the objects are drawn first into two pictures with
// the SAME camera as the volume: their colour, and how far along each viewing ray the nearest
// object is. The volume ray caster then stops each ray at that distance and lays the object's
// colour under what the ray passed (see BKVolumeRenderer geometryColorTexture /
// geometryRayDistanceTexture).
//
// Why a protocol: BorosKitRender (volumes) must not depend on BorosKitMeshRender (meshes), which
// already depends on it. BKMeshGeometryLayer (BorosKitMeshRender) is the implementation that
// draws BKMeshObject / BKLineObject / BKPointObject; a test or another backend can bring its own.
//
// PORTING NOTES (Vulkan): the contract is two images - RGBA colour premultiplied by opacity and
// R32F ray distance in mm (+infinity = nothing) - written in the same command stream before the
// ray-cast. A Vulkan backend needs a pipeline barrier (colour attachment write -> compute read)
// between the two passes; Metal orders them automatically within one command buffer.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "BKVolumeCamera.h"

NS_ASSUME_NONNULL_BEGIN

@protocol BKVolumeGeometryLayer <NSObject>

// What: encodes the objects, seen through `camera` (patient mm), into a picture of width x height
// pixels in `commandBuffer` (no waiting), and returns the two pictures (they stay valid until the
// next call; the same command buffer then reads them). Returns NO when there is nothing to draw
// (no visible objects) or on failure; the volume is then drawn without objects.
// aspectRatio: width / height, as the volume renderer's camera uses it.
- (BOOL)encodeGeometryWithCamera:(BKVolumeCamera *)camera
                           width:(NSUInteger)width
                          height:(NSUInteger)height
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    colorTexture:(id<MTLTexture> _Nullable * _Nonnull)colorTexture
              rayDistanceTexture:(id<MTLTexture> _Nullable * _Nonnull)rayDistanceTexture;

@end

NS_ASSUME_NONNULL_END
