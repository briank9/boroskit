// BorosKitDisplay: BKImage + BKImageLayerRenderer implementation. See the header.

/* BOROS OVERVIEW (plain language)
 * This file does the heavy lifting that turns a CT slice into a picture on screen.
 * It takes the grey-scale pixel numbers from the scan, sends them to the graphics
 * chip (Metal), and applies the brightness and contrast setting (window/level), so
 * bone, soft tissue and air look the way the clinician expects.
 * It also keeps a private copy of the image, so the picture stays valid even when
 * the app reuses its own memory while the user scrolls through slices.
 * The image view asks this file to repaint every time the picture changes.
 */

#import "BKImageLayerRenderer.h"
#import "BKDisplayShaderTypes.h"

extern NSString *BKDisplayShaderSource(void);

static NSString * const BKDisplayErrorDomain = @"BorosKitDisplay";

// What: builds an NSError for this module. Why: one place for the domain string.
static NSError *BKDisplayError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKDisplayErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

#pragma mark - BKImage

@implementation BKImage

// What: copies the caller's pixels. Why: the display may outlive the caller's buffer
// (Horos frees/reuses DCMPix buffers when scrolling).
- (instancetype)initWithFloatPixels:(const float *)pixels width:(NSUInteger)width height:(NSUInteger)height
                      pixelSpacingX:(double)spacingX pixelSpacingY:(double)spacingY
{
    NSData *data = [NSData dataWithBytes:pixels length:sizeof(float) * width * height];
    return [self initWithFloatData:data width:width height:height pixelSpacingX:spacingX pixelSpacingY:spacingY];
}

// What: wraps existing float data (no copy if immutable). Why: avoids a second copy when
// the caller already owns an NSData (e.g. a BKRenderResult's floatData).
- (instancetype)initWithFloatData:(NSData *)data width:(NSUInteger)width height:(NSUInteger)height
                    pixelSpacingX:(double)spacingX pixelSpacingY:(double)spacingY
{
    NSParameterAssert(data.length >= sizeof(float) * width * height);
    if ((self = [super init])) {
        _floatData = [data copy];
        _width = width;
        _height = height;
        _pixelSpacingX = spacingX > 0 ? spacingX : 1.0;
        _pixelSpacingY = spacingY > 0 ? spacingY : 1.0;
        _origin = N3VectorZero;
        _rowDirection = N3VectorMake(1, 0, 0);
        _columnDirection = N3VectorMake(0, 1, 0);
    }
    return self;
}

// What: reads one pixel value. Why: pixel-value readout under the cursor and tests.
- (float)valueAtX:(NSUInteger)x y:(NSUInteger)y
{
    NSParameterAssert(x < _width && y < _height);
    return ((const float *)_floatData.bytes)[y * _width + x];
}

@end

#pragma mark - BKImageLayerRenderer

@implementation BKImageLayerRenderer {
    id<MTLLibrary> _library;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines; // per pixel format
    id<MTLTexture> _imageTexture;
    id<MTLTexture> _lutTexture;      // 256 x 1 RGBA8, always valid (identity gray if no table)
}

// What: compiles the display shaders once per GPU and shares them.
// Why: compiling is the slow part of creating a renderer; every view on screen has one.
+ (id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device error:(NSError **)error
{
    static NSMapTable<id<MTLDevice>, id<MTLLibrary>> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized (cache) {
        id<MTLLibrary> library = [cache objectForKey:device];
        if (!library) {
            library = [device newLibraryWithSource:BKDisplayShaderSource() options:[[MTLCompileOptions alloc] init] error:error];
            if (library) [cache setObject:library forKey:device];
        }
        return library;
    }
}

// What: sets up the GPU objects and Horos-like defaults (WL 40/400, nearest, black).
// Why: a renderer must be usable immediately; failure (no Metal) is reported, not thrown.
- (nullable instancetype)initWithDevice:(nullable id<MTLDevice>)device error:(NSError **)error
{
    if ((self = [super init])) {
        _device = device ?: MTLCreateSystemDefaultDevice();
        if (!_device) {
            if (error) *error = BKDisplayError(1, @"No Metal device available");
            return nil;
        }
        _library = [BKImageLayerRenderer libraryForDevice:_device error:error];
        if (!_library)
            return nil;
        _commandQueue = [_device newCommandQueue];
        _pipelines = [NSMutableDictionary dictionary];
        _windowCenter = 40;
        _windowWidth = 400;
        _interpolation = BKImageInterpolationNearest;
        _backgroundColor = BKColorMake(0, 0, 0, 1);
        _viewTransform = BKViewTransformMakeFit(1, 1, 1, 1);
        [self updateLUTTexture];
    }
    return self;
}

// What: returns (and caches) the render pipeline for a target pixel format.
// Why: a CAMetalLayer uses BGRA8 while offscreen tests use RGBA8; Metal needs one
// pipeline per format.
- (nullable id<MTLRenderPipelineState>)pipelineForPixelFormat:(MTLPixelFormat)format error:(NSError **)error
{
    id<MTLRenderPipelineState> pipeline = _pipelines[@(format)];
    if (pipeline)
        return pipeline;
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [_library newFunctionWithName:@"bk_display_vertex"];
    desc.fragmentFunction = [_library newFunctionWithName:@"bk_display_fragment"];
    desc.colorAttachments[0].pixelFormat = format;
    pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:error];
    if (pipeline)
        _pipelines[@(format)] = pipeline;
    return pipeline;
}

// What: stores the image and uploads it as a 32-bit float texture; keeps the transform's
// image size in sync. Why: full float precision on the GPU means window/level acts on
// real CT values, like Horos' float pipeline, with no 8/16-bit pre-quantising.
- (void)setImage:(nullable BKImage *)image
{
    _image = image;
    _imageTexture = nil;
    if (!image || image.width == 0 || image.height == 0)
        return;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                    width:image.width
                                                                                   height:image.height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    // Intel Macs with a discrete GPU cannot use shared textures; managed works everywhere
    // on macOS. Apple-silicon and iOS GPUs share memory with the CPU.
    desc.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
#else
    desc.storageMode = MTLStorageModeShared;
#endif
    id<MTLTexture> texture = [_device newTextureWithDescriptor:desc];
    [texture replaceRegion:MTLRegionMake2D(0, 0, image.width, image.height)
               mipmapLevel:0
                 withBytes:image.floatData.bytes
               bytesPerRow:sizeof(float) * image.width];
    _imageTexture = texture;

    BKViewTransform t = _viewTransform;
    t.imageWidth = image.width;
    t.imageHeight = image.height;
    t.pixelSpacingX = image.pixelSpacingX;
    t.pixelSpacingY = image.pixelSpacingY;
    _viewTransform = t;
}

// What: stores the colour table and rebuilds its GPU texture.
// Why: the LUT is applied on the GPU after window/level, like Horos' CLUT menu.
- (void)setColorTable:(nullable NSData *)colorTable
{
    if (colorTable && colorTable.length < 768) {
        NSLog(@"BKImageLayerRenderer: colour table needs 768 bytes (256 x RGB); ignored");
        colorTable = nil;
    }
    _colorTable = [colorTable copy];
    [self updateLUTTexture];
}

// What: (re)creates the 256 x 1 RGBA8 lookup texture from `colorTable` (or a gray ramp).
// Why: the shader always binds a LUT texture; a gray ramp keeps the binding valid even
// when no table is selected (the shader skips it in that case).
- (void)updateLUTTexture
{
    uint8_t rgba[256 * 4];
    const uint8_t *rgb = _colorTable.bytes;
    for (int i = 0; i < 256; i++) {
        rgba[i * 4 + 0] = rgb ? rgb[i * 3 + 0] : (uint8_t)i;
        rgba[i * 4 + 1] = rgb ? rgb[i * 3 + 1] : (uint8_t)i;
        rgba[i * 4 + 2] = rgb ? rgb[i * 3 + 2] : (uint8_t)i;
        rgba[i * 4 + 3] = 255;
    }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:256 height:1 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    desc.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
#else
    desc.storageMode = MTLStorageModeShared;
#endif
    _lutTexture = [_device newTextureWithDescriptor:desc];
    [_lutTexture replaceRegion:MTLRegionMake2D(0, 0, 256, 1) mipmapLevel:0 withBytes:rgba bytesPerRow:256 * 4];
}

// What: keeps the image size in the transform authoritative when callers set a transform.
// Why: callers adjust zoom/pan/rotation; the image dimensions must always match the
// uploaded texture, or the shader would sample the wrong pixels.
- (void)setViewTransform:(BKViewTransform)viewTransform
{
    if (_image) {
        viewTransform.imageWidth = _image.width;
        viewTransform.imageHeight = _image.height;
    }
    _viewTransform = viewTransform;
}

// What: fills the shared parameter block for the shader. Why: one place that converts the
// Objective-C state (transform, window, flags) into the GPU layout.
- (BKDisplayParams)paramsWithScale:(CGFloat)scale
{
    BKDisplayParams p;
    memset(&p, 0, sizeof(p));
    CGAffineTransform inv = BKViewTransformViewToImage(_viewTransform);
    p.m_a = inv.a; p.m_b = inv.b; p.m_c = inv.c; p.m_d = inv.d; p.m_tx = inv.tx; p.m_ty = inv.ty;
    p.scale = scale > 0 ? scale : 1.0;
    p.imageWidth = _image ? _image.width : 0;
    p.imageHeight = _image ? _image.height : 0;
    p.windowLower = _windowCenter - _windowWidth * 0.5;
    p.windowWidth = _windowWidth;
    p.interpolation = _interpolation;
    p.useColorTable = _colorTable != nil;
    p.invert = _invert;
    p.bgR = _backgroundColor.red; p.bgG = _backgroundColor.green; p.bgB = _backgroundColor.blue; p.bgA = _backgroundColor.alpha;
    return p;
}

// What: encodes one full-target draw. Without an image it only clears to the background.
// Why: the same encode path serves the on-screen layer and offscreen rendering.
- (BOOL)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer texture:(id<MTLTexture>)texture
                        scale:(CGFloat)scale error:(NSError **)error
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(_backgroundColor.red, _backgroundColor.green,
                                                            _backgroundColor.blue, _backgroundColor.alpha);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        if (error) *error = BKDisplayError(2, @"Could not create a render encoder");
        return NO;
    }
    if (_imageTexture) {
        id<MTLRenderPipelineState> pipeline = [self pipelineForPixelFormat:texture.pixelFormat error:error];
        if (!pipeline) {
            [encoder endEncoding];
            return NO;
        }
        BKDisplayParams params = [self paramsWithScale:scale];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:_imageTexture atIndex:0];
        [encoder setFragmentTexture:_lutTexture atIndex:1];
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    return YES;
}

// What: renders into a private texture, copies it to a CPU-visible buffer and waits.
// Why: tests and exports need the pixels back; going through a buffer works on every
// GPU type (unified or discrete) without platform-specific synchronisation.
- (nullable NSData *)renderRGBA8WithWidth:(NSUInteger)width height:(NSUInteger)height
                                    scale:(CGFloat)scale error:(NSError **)error
{
    if (width == 0 || height == 0) {
        if (error) *error = BKDisplayError(3, @"Empty output size");
        return nil;
    }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:width height:height mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
    id<MTLBuffer> readback = [_device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (![self encodeToCommandBuffer:commandBuffer texture:target scale:scale error:error])
        return nil;
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                 toBuffer:readback destinationOffset:0
   destinationBytesPerRow:width * 4 destinationBytesPerImage:width * height * 4];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.error) {
        if (error) *error = commandBuffer.error;
        return nil;
    }
    return [NSData dataWithBytes:readback.contents length:width * height * 4];
}

@end
