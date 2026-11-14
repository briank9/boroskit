// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: BKSurfaceExtractor implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * This file is the thin Metal layer of surface building: it makes the GPU memory
 * blocks, starts the four GPU programs of BKSurfaceShaderSource.mm in the right order
 * and turns the result into a BKMesh. All the thinking (grid size, memory checks,
 * the marching-cubes table, adding up row totals) lives in the plain-C core
 * (BKSurfaceCore.c) so a future Vulkan version can reuse it unchanged.
 *
 * Order of work for one call:
 *   1. plan (core): grid size, blur weights, memory needed; refuse if too big;
 *   2. if the resolution is below 1 or smoothing is on: sample the scan into a 16-bit
 *      working copy and blur it (x, y, z), then free the spare copy;
 *   3. for each threshold: classify (count crossings per row) -> CPU adds up the row
 *      totals -> exact-size result buffers -> emit (write vertices and triangles) ->
 *      copy into a BKMesh, free the result buffers.
 */

#import "BKSurfaceExtractor.h"
#import "BKSurfaceCore.h"
#import "BKVolumeTexture.h"
#import "BKMesh.h"
#import <QuartzCore/QuartzCore.h>

NSString *BKSurfaceShaderSource(void); // BKSurfaceShaderSource.mm

NSErrorDomain const BKSurfaceErrorDomain = @"BKSurfaceErrorDomain";

// What: an NSError for a core status, with its plain-language message.
static NSError *BKSurfaceError(BKSurfaceStatus status, NSString *_Nullable detail, NSError *_Nullable underlying)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *message = @(BKSurfaceStatusMessage(status));
    info[NSLocalizedDescriptionKey] = detail ? [NSString stringWithFormat:@"%@ %@", message, detail] : message;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:BKSurfaceErrorDomain code:status userInfo:info];
}

// What: milliseconds since some fixed moment. Why: for the timings.
static double BKNowMs(void)
{
    return CACurrentMediaTime() * 1000.0;
}

#pragma mark - Options and timings

@implementation BKSurfaceOptions

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _resolution = 1.0f;
    _scanSmoothing = 0.0f;
    _sampling = BKSurfaceSamplingHardwareLinear;
    _outputTransform = matrix_identity_float4x4;
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    BKSurfaceOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.resolution = _resolution;
    copy.scanSmoothing = _scanSmoothing;
    copy.sampling = _sampling;
    copy.outputTransform = _outputTransform;
    copy.hasOutputTransform = _hasOutputTransform;
    return copy;
}

@end

@interface BKSurfaceTimings ()
@property (nonatomic, readwrite) double samplingMilliseconds;
@property (nonatomic, readwrite) double extractionMilliseconds;
@property (nonatomic, readwrite) double meshMilliseconds;
@property (nonatomic, readwrite) double totalMilliseconds;
@property (nonatomic, readwrite) NSUInteger vertexCount;
@property (nonatomic, readwrite) NSUInteger triangleCount;
@property (nonatomic, readwrite) NSUInteger gridWidth, gridHeight, gridDepth;
@property (nonatomic, readwrite) NSUInteger peakTemporaryBytes;
@end

@implementation BKSurfaceTimings

- (NSDictionary<NSString *, NSNumber *> *)dictionaryRepresentation
{
    return @{
        @"samplingMilliseconds": @(_samplingMilliseconds),
        @"extractionMilliseconds": @(_extractionMilliseconds),
        @"meshMilliseconds": @(_meshMilliseconds),
        @"totalMilliseconds": @(_totalMilliseconds),
        @"vertexCount": @(_vertexCount),
        @"triangleCount": @(_triangleCount),
        @"gridWidth": @(_gridWidth),
        @"gridHeight": @(_gridHeight),
        @"gridDepth": @(_gridDepth),
        @"peakTemporaryBytes": @(_peakTemporaryBytes),
    };
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<BKSurfaceTimings grid %lux%lux%lu: sampling %.1f ms, extraction %.1f ms, mesh %.1f ms, total %.1f ms; %lu vertices, %lu triangles, peak %.1f MB>",
            (unsigned long)_gridWidth, (unsigned long)_gridHeight, (unsigned long)_gridDepth,
            _samplingMilliseconds, _extractionMilliseconds, _meshMilliseconds, _totalMilliseconds,
            (unsigned long)_vertexCount, (unsigned long)_triangleCount, _peakTemporaryBytes / 1048576.0];
}

@end

#pragma mark - Extractor

@implementation BKSurfaceExtractor {
    id<MTLComputePipelineState> _samplePipeline;
    id<MTLComputePipelineState> _blurPipeline;
    id<MTLComputePipelineState> _classifyPipeline;
    id<MTLComputePipelineState> _emitPipeline;
    id<MTLSamplerState> _linearSampler;
    id<MTLBuffer> _table;            // the generated marching-cubes table (read-only, shared by all calls)
    NSUInteger _classifyThreads;     // threads per row workgroup (power of two <= BK_SURFACE_ROW_THREADS)
    NSUInteger _emitThreads;
    NSDictionary *_lastTimings;
}

// What: compiles the shader library once per GPU (compiling is the slow part).
+ (id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device error:(NSError **)error
{
    static NSMapTable<id<MTLDevice>, id<MTLLibrary>> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized (cache) {
        id<MTLLibrary> library = [cache objectForKey:device];
        if (!library) {
            library = [device newLibraryWithSource:BKSurfaceShaderSource() options:[[MTLCompileOptions alloc] init] error:error];
            if (library) [cache setObject:library forKey:device];
        }
        return library;
    }
}

// What: largest power of two <= min(limit, BK_SURFACE_ROW_THREADS). Why: the row
// workgroups need an even size (pairs of 16-bit values) and the scan's shared arrays
// hold BK_SURFACE_ROW_THREADS entries.
static NSUInteger BKRowThreads(id<MTLComputePipelineState> pipeline)
{
    NSUInteger limit = MIN((NSUInteger)BK_SURFACE_ROW_THREADS, pipeline.maxTotalThreadsPerThreadgroup);
    NSUInteger n = 2;
    while (n * 2 <= limit) n *= 2;
    return n;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    return [self initWithDevice:device commandQueue:nil error:error];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device ?: MTLCreateSystemDefaultDevice();
    if (!_device) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusGPUFailed, @"No Metal GPU is available.", nil);
        return nil;
    }
    id<MTLLibrary> library = [[self class] libraryForDevice:_device error:error];
    if (!library) return nil;
    _samplePipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_surface_sample"] error:error];
    _blurPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_surface_blur"] error:error];
    _classifyPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_surface_classify"] error:error];
    _emitPipeline = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bk_surface_emit"] error:error];
    if (!_samplePipeline || !_blurPipeline || !_classifyPipeline || !_emitPipeline) return nil;
    _classifyThreads = BKRowThreads(_classifyPipeline);
    _emitThreads = BKRowThreads(_emitPipeline);

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.normalizedCoordinates = YES;
    _linearSampler = [_device newSamplerStateWithDescriptor:sd];

    uint32_t words[BK_SURFACE_TABLE_WORDS];
    BKSurfaceFillGPUTable(words);
    _table = [_device newBufferWithBytes:words length:sizeof words options:MTLResourceStorageModeShared];
    _table.label = @"BorosKit surface MC table";

    _commandQueue = commandQueue ?: [_device newCommandQueue];
    if (!_linearSampler || !_table || !_commandQueue) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusOutOfMemory, nil, nil);
        return nil;
    }
    return self;
}

- (NSDictionary *)lastTimings
{
    @synchronized (self) { return _lastTimings; }
}

// What: patient -> voxel (BKVolumeTexture.volumeTransform, row-vector convention) turned
// into a voxel -> patient column-major double matrix. Why: the core works with plain
// matrices and should not depend on the Horos-derived geometry types.
static simd_double4x4 BKVoxelToPatient(BKVolumeTexture *volume)
{
    N3AffineTransform t = volume.volumeTransform;
    // Row-vector x' = x * T  <=>  column-vector x' = T^T x: simd columns = rows of T.
    simd_double4x4 patientToVoxel = simd_matrix(simd_make_double4(t.m11, t.m12, t.m13, t.m14),
                                                simd_make_double4(t.m21, t.m22, t.m23, t.m24),
                                                simd_make_double4(t.m31, t.m32, t.m33, t.m34),
                                                simd_make_double4(t.m41, t.m42, t.m43, t.m44));
    return simd_inverse(patientToVoxel);
}

// What: runs a command buffer to the end. Returns NO + error if the GPU failed.
static BOOL BKRun(id<MTLCommandBuffer> cb, NSError **error)
{
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusGPUFailed, nil, cb.error);
        return NO;
    }
    return YES;
}

// What: a dispatch over the "pairs" grid used by sample and blur (one thread per two
// grid points along x). Threadgroup counts are rounded up; the kernels skip extras.
static void BKDispatchPairs(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pipeline, const BKSurfacePlan *plan)
{
    MTLSize tg = MTLSizeMake(MIN((NSUInteger)32, pipeline.threadExecutionWidth), 4, 2);
    while (tg.width * tg.height * tg.depth > pipeline.maxTotalThreadsPerThreadgroup && tg.depth > 1) tg.depth /= 2;
    while (tg.width * tg.height * tg.depth > pipeline.maxTotalThreadsPerThreadgroup && tg.height > 1) tg.height /= 2;
    MTLSize groups = MTLSizeMake((plan->rowStride / 2 + tg.width - 1) / tg.width,
                                 (plan->gridHeight + tg.height - 1) / tg.height,
                                 (plan->gridDepth + tg.depth - 1) / tg.depth);
    [enc dispatchThreadgroups:groups threadsPerThreadgroup:tg];
}

- (BKMesh *)extractSurfaceFromVolume:(BKVolumeTexture *)volume threshold:(float)threshold
                          resolution:(float)resolution scanSmoothing:(float)scanSmoothing error:(NSError **)error
{
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.resolution = resolution;
    options.scanSmoothing = scanSmoothing;
    return [self extractSurfacesFromVolume:volume thresholds:@[@(threshold)] options:options timings:NULL error:error].firstObject;
}

- (NSArray<BKMesh *> *)extractSurfacesFromVolume:(BKVolumeTexture *)volume thresholds:(NSArray<NSNumber *> *)thresholds
                                         options:(BKSurfaceOptions *)options timings:(BKSurfaceTimings **)timingsOut
                                           error:(NSError **)error
{
    const double tStart = BKNowMs();
    options = options ?: [[BKSurfaceOptions alloc] init];
    BKSurfaceTimings *timings = [[BKSurfaceTimings alloc] init];
    if (!volume || volume.texture.device != _device || thresholds.count == 0) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusInvalidInput, @"(No volume, a volume from another GPU, or no threshold.)", nil);
        return nil;
    }

    // ---- 1. Plan (backend-neutral core) ----
    BKSurfacePlanRequest rq = {0};
    rq.volumeWidth = (uint32_t)MIN(volume.pixelsWide, (NSUInteger)UINT32_MAX);
    rq.volumeHeight = (uint32_t)MIN(volume.pixelsHigh, (NSUInteger)UINT32_MAX);
    rq.volumeDepth = (uint32_t)MIN(volume.pixelsDeep, (NSUInteger)UINT32_MAX);
    rq.resolution = options.resolution;
    rq.smoothingSigma = options.scanSmoothing;
    rq.sampling = options.sampling == BKSurfaceSamplingManualTrilinear ? BK_SURFACE_SAMPLING_MANUAL : BK_SURFACE_SAMPLING_HARDWARE;
    simd_double4x4 voxelToOutput;
    if (options.hasOutputTransform) {
        for (int c = 0; c < 4; c++) voxelToOutput.columns[c] = simd_double(options.outputTransform.columns[c]);
    } else {
        voxelToOutput = BKVoxelToPatient(volume);
    }
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) rq.voxelToOutput[c * 4 + r] = voxelToOutput.columns[c][r];
    rq.maxBufferBytes = _device.maxBufferLength;
    if ([_device respondsToSelector:@selector(recommendedMaxWorkingSetSize)]) rq.memoryBudgetBytes = _device.recommendedMaxWorkingSetSize;

    BKSurfacePlan plan;
    BKSurfaceStatus status = BKSurfacePlanMake(&rq, &plan);
    if (status != BKSurfaceStatusOK) {
        if (error) *error = BKSurfaceError(status, nil, nil);
        return nil;
    }
    timings.gridWidth = plan.gridWidth;
    timings.gridHeight = plan.gridHeight;
    timings.gridDepth = plan.gridDepth;
    NSMutableArray<NSNumber *> *steps = [NSMutableArray array];
    for (NSNumber *threshold in thresholds) {
        float s = BKSurfaceThresholdToSteps(threshold.floatValue, volume.valueScale, volume.valueOffset);
        if (isnan(s)) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusInvalidInput, @"(The threshold is not a number.)", nil);
            return nil;
        }
        [steps addObject:@(s)];
    }

    // ---- 2. Working copy of the scan (only when resampling or smoothing) ----
    // Temporary buffers are GPU-private (the CPU never looks at them).
    const MTLResourceOptions privateStorage = MTLResourceStorageModePrivate;
    id<MTLBuffer> field = nil;
    uint64_t peakBytes = 0;
    if (plan.usesField) {
        const double t0 = BKNowMs();
        field = [_device newBufferWithLength:plan.fieldBytes options:privateStorage];
        id<MTLBuffer> spare = plan.blurs ? [_device newBufferWithLength:plan.fieldBytes options:privateStorage] : nil;
        if (!field || (plan.blurs && !spare)) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusOutOfMemory, nil, nil);
            return nil;
        }
        peakBytes = plan.fieldBytes * (plan.blurs ? 2 : 1);
        id<MTLCommandBuffer> cb = [_commandQueue commandBuffer];
        cb.label = @"BorosKit surface sampling";
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        BKSurfaceParams params = plan.params;
        [enc setComputePipelineState:_samplePipeline];
        [enc setBytes:&params length:sizeof params atIndex:0];
        [enc setBuffer:field offset:0 atIndex:1];
        [enc setTexture:volume.texture atIndex:0];
        [enc setSamplerState:_linearSampler atIndex:0];
        BKDispatchPairs(enc, _samplePipeline, &plan);
        // Separable blur: x, y, z, each from one buffer into the other. Metal orders
        // dispatches in one encoder that touch the same buffers (Vulkan: add a buffer
        // memory barrier between them).
        for (uint32_t axis = 0; axis < 3; axis++) {
            if (!plan.blurRadius[axis]) continue;
            BKSurfacePlanSetBlurAxis(&plan, axis, &params);
            [enc setComputePipelineState:_blurPipeline];
            [enc setBytes:&params length:sizeof params atIndex:0];
            [enc setBuffer:field offset:0 atIndex:1];
            [enc setBuffer:spare offset:0 atIndex:2];
            BKDispatchPairs(enc, _blurPipeline, &plan);
            id<MTLBuffer> swap = field;   // the blurred copy becomes the field
            field = spare;
            spare = swap;
        }
        [enc endEncoding];
        if (!BKRun(cb, error)) return nil;
        spare = nil;   // freed here, before the extraction buffers are made
        timings.samplingMilliseconds = BKNowMs() - t0;
    }

    // ---- 3. Per threshold: classify -> row prefix sum -> emit -> BKMesh ----
    const double tExtract = BKNowMs();
    double meshMs = 0;
    id<MTLBuffer> packed = [_device newBufferWithLength:plan.packedBytes options:privateStorage];
    id<MTLBuffer> rowVertices = [_device newBufferWithLength:plan.rowTableBytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> rowTriangles = [_device newBufferWithLength:plan.rowTableBytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> dummyField = field ?: [_device newBufferWithLength:16 options:privateStorage];   // unused when reading the texture
    if (!packed || !rowVertices || !rowTriangles || !dummyField) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusOutOfMemory, nil, nil);
        return nil;
    }
    const uint64_t workingBytes = plan.fieldBytes + plan.packedBytes + 2 * plan.rowTableBytes;
    peakBytes = MAX(peakBytes, workingBytes);
    const MTLSize rows = MTLSizeMake(plan.gridHeight, plan.gridDepth, 1);

    NSMutableArray<BKMesh *> *meshes = [NSMutableArray array];
    NSUInteger totalVertices = 0, totalTriangles = 0;
    for (NSNumber *step in steps) {
        BKSurfaceParams params = plan.params;
        params.thresholdSteps = step.floatValue;

        // a) classify every row
        id<MTLCommandBuffer> cb = [_commandQueue commandBuffer];
        cb.label = @"BorosKit surface classify";
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:_classifyPipeline];
        [enc setBytes:&params length:sizeof params atIndex:0];
        [enc setBuffer:dummyField offset:0 atIndex:1];
        [enc setBuffer:packed offset:0 atIndex:2];
        [enc setBuffer:rowVertices offset:0 atIndex:3];
        [enc setBuffer:rowTriangles offset:0 atIndex:4];
        [enc setBuffer:_table offset:0 atIndex:5];
        [enc setTexture:volume.texture atIndex:0];
        [enc dispatchThreadgroups:rows threadsPerThreadgroup:MTLSizeMake(_classifyThreads, 1, 1)];
        [enc endEncoding];
        if (!BKRun(cb, error)) return nil;

        // b) row counts -> row starts (CPU, on the shared memory the GPU just wrote)
        uint64_t vertexCount = BKSurfaceExclusiveScan(rowVertices.contents, plan.rowCount);
        uint64_t triangleCount = BKSurfaceExclusiveScan(rowTriangles.contents, plan.rowCount);
        if (vertexCount == UINT64_MAX || triangleCount == UINT64_MAX || triangleCount * 3 > UINT32_MAX) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusTooLarge, nil, nil);
            return nil;
        }
        if (triangleCount == 0) {   // nothing crosses the threshold: an empty mesh, not an error
            [meshes addObject:[[BKMesh alloc] init]];
            continue;
        }

        // c) exact-size result buffers (shared: the CPU copies them into the BKMesh)
        const uint64_t outBytes = BKSurfaceOutputBytes(vertexCount, triangleCount);
        if (vertexCount * 16 > _device.maxBufferLength || triangleCount * 12 > _device.maxBufferLength ||
            (rq.memoryBudgetBytes && workingBytes + outBytes > rq.memoryBudgetBytes)) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusTooLarge, nil, nil);
            return nil;
        }
        id<MTLBuffer> positions = [_device newBufferWithLength:vertexCount * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> normals = [_device newBufferWithLength:vertexCount * 16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> indices = [_device newBufferWithLength:triangleCount * 12 options:MTLResourceStorageModeShared];
        if (!positions || !normals || !indices) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusOutOfMemory, nil, nil);
            return nil;
        }
        peakBytes = MAX(peakBytes, workingBytes + outBytes);

        // d) emit vertices and triangles
        cb = [_commandQueue commandBuffer];
        cb.label = @"BorosKit surface emit";
        enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:_emitPipeline];
        [enc setBytes:&params length:sizeof params atIndex:0];
        [enc setBuffer:dummyField offset:0 atIndex:1];
        [enc setBuffer:packed offset:0 atIndex:2];
        [enc setBuffer:rowVertices offset:0 atIndex:3];
        [enc setBuffer:rowTriangles offset:0 atIndex:4];
        [enc setBuffer:_table offset:0 atIndex:5];
        [enc setBuffer:positions offset:0 atIndex:6];
        [enc setBuffer:normals offset:0 atIndex:7];
        [enc setBuffer:indices offset:0 atIndex:8];
        [enc setTexture:volume.texture atIndex:0];
        [enc dispatchThreadgroups:rows threadsPerThreadgroup:MTLSizeMake(_emitThreads, 1, 1)];
        [enc endEncoding];
        if (!BKRun(cb, error)) return nil;

        // e) one copy into the BKMesh. The GPU wrote 16 bytes per point (x, y, z, unused),
        // which is exactly the memory layout of simd_float3, so no conversion is needed.
        const double tMesh = BKNowMs();
        BKMesh *mesh = [[BKMesh alloc] initWithVertices:(const simd_float3 *)positions.contents vertexCount:(NSUInteger)vertexCount
                                                indices:(const uint32_t *)indices.contents indexCount:(NSUInteger)triangleCount * 3
                                                normals:(const simd_float3 *)normals.contents colors:NULL error:error];
        meshMs += BKNowMs() - tMesh;
        if (!mesh) return nil;
        [meshes addObject:mesh];
        totalVertices += vertexCount;
        totalTriangles += triangleCount;
    }

    timings.extractionMilliseconds = BKNowMs() - tExtract - meshMs;
    timings.meshMilliseconds = meshMs;
    timings.vertexCount = totalVertices;
    timings.triangleCount = totalTriangles;
    timings.peakTemporaryBytes = (NSUInteger)peakBytes;
    timings.totalMilliseconds = BKNowMs() - tStart;
    @synchronized (self) { _lastTimings = timings.dictionaryRepresentation; }
    if (timingsOut) *timingsOut = timings;
    return meshes;
}

@end
