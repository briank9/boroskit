// BorosKitMeshRender: BKMeshGeometryLayer (see the header).
//
// Original BorosKit code written for this project; contains no third-party code.

#import "BKMeshGeometryLayer.h"

@implementation BKMeshGeometryLayer {
    id<MTLTexture> _colorTexture;      // RGBA8, premultiplied colour (render target + shader read)
    id<MTLTexture> _distanceTexture;   // R32F ray distance, +infinity = nothing
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _renderer = [[BKMeshRenderer alloc] initWithDevice:device error:error];
    if (_renderer == nil) return nil;
    _objects = @[];
    _lineObjects = @[];
    _pointObjects = @[];
    return self;
}

// What: is anything visible? Why: with nothing to draw the volume is ray-cast alone (no extra
// GPU pass, no textures read).
- (BOOL)hasVisibleObjects
{
    for (BKMeshObject *o in _objects) if (o.visible && o.opacity > 0) return YES;
    for (BKLineObject *l in _lineObjects) if (l.visible && l.opacity > 0) return YES;
    for (BKPointObject *p in _pointObjects) if (p.visible && p.opacity > 0) return YES;
    return NO;
}

// What: makes sure both pictures exist at width x height (re-made only when the size changes).
- (BOOL)ensureTexturesWidth:(NSUInteger)width height:(NSUInteger)height
{
    if (_colorTexture && _colorTexture.width == width && _colorTexture.height == height) return YES;
    id<MTLDevice> device = _renderer.device;
    MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:width height:height mipmapped:NO];
    cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    cd.storageMode = MTLStorageModePrivate;
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                  width:width height:height mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    dd.storageMode = MTLStorageModePrivate;
    _colorTexture = [device newTextureWithDescriptor:cd];
    _distanceTexture = [device newTextureWithDescriptor:dd];
    return _colorTexture != nil && _distanceTexture != nil;
}

// What: see BKVolumeGeometryLayer.h. Draws the objects with the volume's camera (the same
// -setCameraFromVolumeCamera:aspectRatio: rule as -[BKVolumeCamera applyToRenderer:...]) into
// the two pictures, cleared to transparent / +infinity first.
// Note: the pictures are reused frame after frame. That is safe because every frame's work goes
// through the volume view's one command queue in order (this frame's drawing finishes before
// the next frame's starts).
- (BOOL)encodeGeometryWithCamera:(BKVolumeCamera *)camera width:(NSUInteger)width height:(NSUInteger)height
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    colorTexture:(id<MTLTexture> *)colorTexture
              rayDistanceTexture:(id<MTLTexture> *)rayDistanceTexture
{
    *colorTexture = nil;
    *rayDistanceTexture = nil;
    if (width == 0 || height == 0 || ![self hasVisibleObjects]) return NO;
    if (![self ensureTexturesWidth:width height:height]) return NO;
    _renderer.objects = _objects;
    _renderer.lineObjects = _lineObjects;
    _renderer.pointObjects = _pointObjects;
    _renderer.viewport = CGRectZero;   // the whole picture
    [_renderer setCameraFromVolumeCamera:camera aspectRatio:(CGFloat)width / (CGFloat)height];
    NSError *error = nil;
    if (![_renderer encodeRenderToColorTexture:_colorTexture rayDistanceTexture:_distanceTexture
                                 commandBuffer:commandBuffer clear:YES clearColor:simd_make_float4(0, 0, 0, 0)
                                         error:&error]) {
        NSLog(@"BorosKit geometry layer: objects not drawn (%@)", error.localizedDescription);
        return NO;
    }
    *colorTexture = _colorTexture;
    *rayDistanceTexture = _distanceTexture;
    return YES;
}

@end
