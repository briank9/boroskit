// BorosKitRender: private extra storage on BKVolumeTexture for empty-space skipping.
//
// What: a slot where the renderer keeps the per-brick lowest/highest values of this
// volume (see BK_BRICK_SIZE in BKShaderTypes.h).
// Why here: the values belong to the volume, not to one renderer. Several views can
// share one uploaded volume, and this way the work is done only once per volume.
// Not part of the public headers: apps never need to touch it.

#import "BKVolumeTexture.h"

NS_ASSUME_NONNULL_BEGIN

@interface BKVolumeTexture ()

// One (lowest, highest) pair of raw 16-bit values per brick, packed in one 32-bit word
// (lowest | highest << 16), filled on the GPU the
// first time a renderer needs it. nil until then.
@property (nonatomic, strong, nullable) id<MTLBuffer> brickRangeBuffer;

@end

NS_ASSUME_NONNULL_END
