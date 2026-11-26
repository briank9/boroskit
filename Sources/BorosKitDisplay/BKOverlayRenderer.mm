// BorosKitDisplay: BKOverlayRenderer - see BKOverlayRenderer.h (Metal glue for BKOverlayCore).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly (shaders + per-command state below; GLSL noted).

#import "BKOverlayRenderer.h"
#import "BKMetalDevice.h"

// What: the two shaders. Vertex: view pixels (y down) -> clip space. Fragment: solid colour, image x
// colour, or mask x colour; straight alpha in, premultiplied out (blend: one, one-minus-source-alpha).
//
// GLSL equivalent (Vulkan, set 0: binding 0 sampler2D image; push constants: vec2 viewSize, int mode,
// int opaque):
//   vertex:   gl_Position = vec4(pos.x / viewSize.x * 2 - 1, 1 - pos.y / viewSize.y * 2, 0, 1)  (+ y flip)
//   fragment: vec4 c = color; if (mode == 1) c *= texture(image, uv / textureSize(image, 0));
//             if (mode == 2) c.a *= texture(image, uv / textureSize(image, 0)).r;
//             if (opaque != 0) c.a = 1; out = vec4(c.rgb * c.a, c.a);
// 2026-11-25 (vulkan-engine M2): BKOverlayParams is no longer typed here by hand - its field list
// BK_OVERLAY_PARAMS_FIELDS (BKOverlayCore.h) is pasted in, the same text the C side uses.
#define BKO_STR_(...) #__VA_ARGS__
#define BKO_STR(...) BKO_STR_(__VA_ARGS__)
static NSString *BKOverlayShaderSource(void)
{
    const char *head = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct BKOverlayVertexIn {          // = BKOverlayVertex (32 bytes)
    float2 position;
    float2 uv;
    float4 color;
};
)METAL";
    // The names the shared field list uses, in Metal (C: BKGPUTypes.h / <stdint.h>).
    const char *params = "typedef float2 bk_float2;\n"
                         "typedef int int32_t;\n"
                         "struct BKOverlayParams { " BKO_STR(BK_OVERLAY_PARAMS_FIELDS) " };\n";
    const char *body = R"METAL(

struct BKOverlayVaryings {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex BKOverlayVaryings bk_overlay_vertex(const device BKOverlayVertexIn *vertices [[buffer(0)]],
                                           constant BKOverlayParams &p [[buffer(1)]],
                                           uint vid [[vertex_id]])
{
    BKOverlayVertexIn v = vertices[vid];
    BKOverlayVaryings o;
    o.position = float4(v.position.x / p.viewSize.x * 2.0 - 1.0, 1.0 - v.position.y / p.viewSize.y * 2.0, 0.0, 1.0);
    o.uv = v.uv;
    o.color = v.color;
    return o;
}

fragment float4 bk_overlay_fragment(BKOverlayVaryings in [[stage_in]],
                                    constant BKOverlayParams &p [[buffer(0)]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler smp [[sampler(0)]])
{
    float4 c = in.color;
    if (p.mode != 0) {
        float4 t = image.sample(smp, in.uv / p.imageSize);
        if (p.mode == 1) c *= t;
        else c.a *= t.r;
    }
    if (p.opaque != 0) c.a = 1.0;
    return float4(c.rgb * c.a, c.a);
}
)METAL";
    return [NSString stringWithFormat:@"%s%s%s", head, params, body];
}

@implementation BKOverlayRenderer {
    id<MTLLibrary> _library;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;   // key: pixel format
    id<MTLSamplerState> _nearest, _linear;
    id<MTLTexture> _white;   // bound when a command has no image (Metal wants a texture)
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device;
    _library = [device newLibraryWithSource:BKOverlayShaderSource() options:[BKMetalDevice shaderCompileOptions] error:error];
    if (!_library) return nil;
    _pipelines = [NSMutableDictionary dictionary];
    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    _nearest = [device newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    _linear = [device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    _white = [device newTextureWithDescriptor:td];
    const uint8_t w[4] = { 255, 255, 255, 255 };
    [_white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:w bytesPerRow:4];
    return self;
}

// One pipeline per colour format: premultiplied source-over (opaque commands set alpha 1 in the shader,
// which makes the same blend draw opaque).
- (id<MTLRenderPipelineState>)pipelineForFormat:(MTLPixelFormat)format error:(NSError **)error
{
    id<MTLRenderPipelineState> p = _pipelines[@(format)];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [_library newFunctionWithName:@"bk_overlay_vertex"];
    d.fragmentFunction = [_library newFunctionWithName:@"bk_overlay_fragment"];
    d.colorAttachments[0].pixelFormat = format;
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    p = [_device newRenderPipelineStateWithDescriptor:d error:error];
    if (p) _pipelines[@(format)] = p;
    return p;
}

- (BOOL)encodeList:(const BKOverlayList *)list encoder:(id<MTLRenderCommandEncoder>)encoder
       pixelFormat:(MTLPixelFormat)format width:(uint32_t)width height:(uint32_t)height error:(NSError **)error
{
    uint32_t nv = 0, nc = 0, ni = 0;
    const BKOverlayVertex *v = BKOverlayListVertices(list, &nv);
    const BKOverlayCommand *c = BKOverlayListCommands(list, &nc);
    const BKOverlayImage *im = BKOverlayListImages(list, &ni);
    if (nv == 0 || nc == 0 || width == 0 || height == 0) return YES;   // nothing to draw
    id<MTLRenderPipelineState> pipeline = [self pipelineForFormat:format error:error];
    if (!pipeline) return NO;

    id<MTLBuffer> vb = [_device newBufferWithBytes:v length:sizeof(BKOverlayVertex) * nv options:MTLResourceStorageModeShared];
    NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray arrayWithCapacity:ni];
    for (uint32_t i = 0; i < ni; i++) {
        MTLPixelFormat pf = im[i].kind == BKOverlayImageAlpha8 ? MTLPixelFormatR8Unorm : MTLPixelFormatRGBA8Unorm;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:im[i].width height:im[i].height mipmapped:NO];
        id<MTLTexture> t = [_device newTextureWithDescriptor:td];
        [t replaceRegion:MTLRegionMake2D(0, 0, im[i].width, im[i].height) mipmapLevel:0 withBytes:im[i].pixels
             bytesPerRow:im[i].width * (im[i].kind == BKOverlayImageAlpha8 ? 1 : 4)];
        [textures addObject:t ?: _white];
    }

    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:vb offset:0 atIndex:0];
    for (uint32_t k = 0; k < nc; k++) {
        const BKOverlayCommand *cmd = &c[k];
        if (cmd->count == 0) continue;
        MTLScissorRect sc = { 0, 0, width, height };
        if (cmd->hasClip) {
            long x0 = MAX(0, cmd->clipX), y0 = MAX(0, cmd->clipY);
            long x1 = MIN((long)width, (long)cmd->clipX + cmd->clipW), y1 = MIN((long)height, (long)cmd->clipY + cmd->clipH);
            if (x1 <= x0 || y1 <= y0) continue;   // clipped away
            sc = (MTLScissorRect){ (NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0) };
        }
        [encoder setScissorRect:sc];
        BKOverlayParams p;   // the shared GPU block (BKOverlayCore.h)
        p.viewSize = bk_make_float2((float)width, (float)height);
        p.imageSize = bk_make_float2(1, 1);
        p.mode = cmd->mode;
        p.opaque = cmd->ignoreAlpha;
        id<MTLTexture> tex = _white;
        if (cmd->mode != BKOverlayModeSolid && cmd->image >= 0 && (uint32_t)cmd->image < ni) {
            tex = textures[cmd->image];
            p.imageSize = bk_make_float2((float)im[cmd->image].width, (float)im[cmd->image].height);
        } else {
            p.mode = BKOverlayModeSolid;
        }
        [encoder setVertexBytes:&p length:sizeof(p) atIndex:1];
        [encoder setFragmentBytes:&p length:sizeof(p) atIndex:0];
        [encoder setFragmentTexture:tex atIndex:0];
        [encoder setFragmentSamplerState:cmd->linearFilter ? _linear : _nearest atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:cmd->first vertexCount:cmd->count];
    }
    [encoder setScissorRect:(MTLScissorRect){ 0, 0, width, height }];
    return YES;
}

- (BOOL)renderList:(const BKOverlayList *)list intoTexture:(id<MTLTexture>)texture
     commandBuffer:(id<MTLCommandBuffer>)commandBuffer error:(NSError **)error
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    BOOL ok = [self encodeList:list encoder:enc pixelFormat:texture.pixelFormat
                         width:(uint32_t)texture.width height:(uint32_t)texture.height error:error];
    [enc endEncoding];
    return ok;
}

@end
