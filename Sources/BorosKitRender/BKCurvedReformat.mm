// BorosKitRender: BKCurvedReformat - see include/BKCurvedReformat.h (what, why, porting notes).
//
// Original BorosKit code written for this project; contains no third-party code.
// VULKAN: safe to translate directly - the kernel below mirrors BKCurvedReformatCore.c line by line; the
// comments name the GLSL equivalent of each Metal construct.

#import "BKCurvedReformat.h"
#import "BKVolumeTexture.h"
#import "BKMetalDevice.h"
#include <unistd.h>

#define BKR_STR2(x) #x
#define BKR_STR(x) BKR_STR2(x)

static NSError *BKReformatError(NSInteger code, NSString *text)
{
    return [NSError errorWithDomain:@"BKCurvedReformat" code:code userInfo:@{ NSLocalizedDescriptionKey: text }];
}

// The kernel. Metal -> GLSL: `kernel` + [[thread_position_in_grid]] -> compute shader + gl_GlobalInvocationID;
// `constant BKReformatParams &` -> layout(std430) readonly buffer (or uniform block); `device const float4 *`
// -> std430 readonly buffer of vec4; `texture3d<float, access::read>.read(uint3)` -> texelFetch(sampler3D, ivec3, 0)
// (R16_UNORM, normalised 0..1); `device float *` -> std430 writeonly buffer of float; int(float) truncates
// toward zero in both.
static NSString *BKReformatShaderSource(void)
{
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *header =
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "typedef uint uint32_t;\n"
            "typedef int int32_t;\n"
            "struct BKReformatParams { " BKR_STR(BK_REFORMAT_PARAMS_FIELDS) " };\n";
        const char *body = R"(
// Exact voxel read, or outOfBoundsValue outside the scan (GLSL: texelFetch + bounds test).
static float bkr_fetch(texture3d<float, access::read> vol, constant BKReformatParams &p, int x, int y, int z)
{
    if (x < 0 || y < 0 || z < 0 || x >= int(p.volumeWide) || y >= int(p.volumeHigh) || z >= int(p.volumeDeep))
        return p.outOfBoundsValue;
    return vol.read(uint3(x, y, z)).r * p.valueScale + p.valueOffset;
}

static void bkr_cubic_weights(float d, thread float *w)
{
    float d2 = d * d, d3 = d2 * d;
    w[0] = 0.5f * (-d + 2.0f * d2 - d3);
    w[1] = 0.5f * (2.0f - 5.0f * d2 + 3.0f * d3);
    w[2] = 0.5f * (d + 4.0f * d2 - 3.0f * d3);
    w[3] = 0.5f * (-d2 + d3);
}

// Same as BKReformatSample() in BKCurvedReformatCore.c.
static float bkr_sample(texture3d<float, access::read> vol, constant BKReformatParams &p, float3 c)
{
    if (p.interpolation == 0) {   // nearest: (int)(c + 0.5), cut toward zero (classic rule)
        return bkr_fetch(vol, p, int(c.x + 0.5f), int(c.y + 0.5f), int(c.z + 0.5f));
    }
    if (p.interpolation == 1) {   // linear, classic rule: base cut toward zero, whole sample outside if any voxel is
        int3 i0 = int3(c);         // (GLSL: ivec3(c) also cuts toward zero)
        if (i0.x < 0 || i0.y < 0 || i0.z < 0 || i0.x + 1 >= int(p.volumeWide) || i0.y + 1 >= int(p.volumeHigh) ||
            i0.z + 1 >= int(p.volumeDeep))
            return p.outOfBoundsValue;
        float3 d = c - float3(i0);
        float sum = 0.0f;
        for (int k = 0; k < 2; k++)
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    float w = (i ? d.x : 1.0f - d.x) * (j ? d.y : 1.0f - d.y) * (k ? d.z : 1.0f - d.z);
                    sum += w * bkr_fetch(vol, p, i0.x + i, i0.y + j, i0.z + k);
                }
        return sum;
    }
    float3 f = floor(c);
    float3 d = c - f;
    int3 i0 = int3(f);
    float wx[4], wy[4], wz[4];   // cubic (Catmull-Rom)
    bkr_cubic_weights(d.x, wx);
    bkr_cubic_weights(d.y, wy);
    bkr_cubic_weights(d.z, wz);
    float sum = 0.0f;
    for (int k = 0; k < 4; k++) {
        float plane = 0.0f;
        for (int j = 0; j < 4; j++) {
            float line = 0.0f;
            for (int i = 0; i < 4; i++) line += wx[i] * bkr_fetch(vol, p, i0.x + i - 1, i0.y + j - 1, i0.z + k - 1);
            plane += wy[j] * line;
        }
        sum += wz[k] * plane;
    }
    return sum;
}

// One thread per output pixel (GLSL: layout(local_size_x = 8, local_size_y = 8) in; same body).
kernel void bk_curved_reformat(texture3d<float, access::read> vol [[texture(0)]],
                               constant BKReformatParams &p [[buffer(0)]],
                               device const float4 *frames [[buffer(1)]],   // 3 per column: base, row, slab
                               device float *outValues [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    float3 base = frames[gid.x * 3].xyz, row = frames[gid.x * 3 + 1].xyz, slab = frames[gid.x * 3 + 2].xyz;
    float ry = float(gid.y) - p.rowCentre;
    float acc = 0.0f;
    for (uint z = 0; z < p.depth; z++) {
        float rz = float(z) - p.slabCentre;
        float value = bkr_sample(vol, p, base + row * ry + slab * rz);
        if (p.projection == 1)      acc = (z == 0 || value > acc) ? value : acc;                     // MIP
        else if (p.projection == 2) acc = (z == 0 || value < acc) ? value : acc;                     // MinIP
        else if (p.projection == 3) acc = (z == 0) ? value : (acc * float(z) + value) / float(z + 1); // running mean
        else if (p.projection == 4) acc += (max(value, -1000.0f) + 1000.0f) * p.radiographK;        // radiograph sum
        else if (z == 0) acc = value;   // no projection: the first slab sample (classic)
    }
    if (p.projection == 4) acc = 3000.0f - 4000.0f * exp(-acc);
    outValues[gid.y * p.width + gid.x] = acc;
}
)";
        source = [[NSString stringWithUTF8String:header] stringByAppendingString:[NSString stringWithUTF8String:body]];
    });
    return source;
}

@implementation BKCurvedReformat {
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if ((self = [super init])) {
        _device = device ?: MTLCreateSystemDefaultDevice();
        if (_device == nil) {
            if (error) *error = BKReformatError(1, @"No Metal device.");
            return nil;
        }
        id<MTLLibrary> library = [_device newLibraryWithSource:BKReformatShaderSource() options:[BKMetalDevice shaderCompileOptions] error:error];
        id<MTLFunction> function = [library newFunctionWithName:@"bk_curved_reformat"];
        _pipeline = function ? [_device newComputePipelineStateWithFunction:function error:error] : nil;
        _queue = [_device newCommandQueue];
        if (_pipeline == nil || _queue == nil) {
            if (error && *error == nil) *error = BKReformatError(2, @"The curved-MPR kernel could not be built.");
            return nil;
        }
    }
    return self;
}

// What: fills the volume fields of params from the GPU scan.
static BKReformatParams BKReformatWithVolume(BKReformatParams params, BKVolumeTexture *volume)
{
    params.valueScale = volume.valueScale;
    params.valueOffset = volume.valueOffset;
    params.volumeWide = (uint32_t)volume.pixelsWide;
    params.volumeHigh = (uint32_t)volume.pixelsHigh;
    params.volumeDeep = (uint32_t)volume.pixelsDeep;
    return params;
}

- (id<MTLCommandBuffer>)encodeParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                         valueBuffer:(id<MTLBuffer>)valueBuffer error:(NSError **)error
{
    if (volume.texture == nil || frames == NULL || params.width == 0 || params.height == 0 || params.depth == 0) {
        if (error) *error = BKReformatError(3, @"Nothing to draw (no scan, no frames or an empty picture).");
        return nil;
    }
    params = BKReformatWithVolume(params, volume);
    id<MTLBuffer> frameBuffer = [_device newBufferWithBytes:frames length:sizeof(BKReformatFrame) * params.width
                                                    options:MTLResourceStorageModeShared];
    if (frameBuffer == nil) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the column frames.");
        return nil;
    }
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_pipeline];
    [enc setTexture:volume.texture atIndex:0];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBuffer:frameBuffer offset:0 atIndex:1];
    [enc setBuffer:valueBuffer offset:0 atIndex:2];
    [enc dispatchThreadgroups:MTLSizeMake((params.width + 7) / 8, (params.height + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [enc endEncoding];
    [cb commit];
    return cb;
}

- (BOOL)renderParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                into:(float *)destination capacity:(NSUInteger)capacityBytes error:(NSError **)error
{
    NSUInteger bytes = (NSUInteger)params.width * params.height * sizeof(float);
    if (destination == NULL || capacityBytes < bytes || bytes == 0) {
        if (error) *error = BKReformatError(5, @"The destination is missing or too small.");
        return NO;
    }
    NSUInteger page = (NSUInteger)getpagesize();
    BOOL direct = ((uintptr_t)destination % page) == 0 && capacityBytes % page == 0;
    id<MTLBuffer> valueBuffer = direct
        ? [_device newBufferWithBytesNoCopy:destination length:capacityBytes options:MTLResourceStorageModeShared deallocator:nil]
        : [_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (valueBuffer == nil) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the picture.");
        return NO;
    }
    id<MTLCommandBuffer> cb = [self encodeParams:params frames:frames volume:volume valueBuffer:valueBuffer error:error];
    if (cb == nil) return NO;
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = cb.error ?: BKReformatError(6, @"The GPU failed to draw the picture.");
        return NO;
    }
    if (!direct) memcpy(destination, valueBuffer.contents, bytes);
    return YES;
}

- (id<MTLCommandBuffer>)commitParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames volume:(BKVolumeTexture *)volume
                                into:(float *)destination capacity:(NSUInteger)capacityBytes error:(NSError **)error
{
    NSUInteger bytes = (NSUInteger)params.width * params.height * sizeof(float), page = (NSUInteger)getpagesize();
    if (destination == NULL || capacityBytes < bytes || bytes == 0 || ((uintptr_t)destination % page) != 0 || capacityBytes % page != 0) {
        if (error) *error = BKReformatError(7, @"Drawing ahead needs page-aligned memory of whole pages.");
        return nil;
    }
    id<MTLBuffer> valueBuffer = [_device newBufferWithBytesNoCopy:destination length:capacityBytes options:MTLResourceStorageModeShared deallocator:nil];
    if (valueBuffer == nil) {
        if (error) *error = BKReformatError(4, @"Not enough memory for the picture.");
        return nil;
    }
    return [self encodeParams:params frames:frames volume:volume valueBuffer:valueBuffer error:error];
}

+ (void)computeOnCPUParams:(BKReformatParams)params frames:(const BKReformatFrame *)frames voxels:(const float *)voxels into:(float *)destination
{
    if (params.height == 0) return;
    const uint32_t block = 16;   // rows per task; any split gives the same pixels
    size_t tasks = (params.height + block - 1) / block;
    BKReformatParams *p = &params;
    dispatch_apply(tasks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t t) {
        uint32_t start = (uint32_t)t * block;
        BKReformatComputeRows(p, frames, voxels, start, MIN(start + block, p->height), destination);
    });
}

@end
