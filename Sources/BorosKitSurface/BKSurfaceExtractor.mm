// Original BorosKit code written for this project; contains no third-party code.
//
// BorosKitSurface: BKSurfaceExtractor implementation (see the header for what it does).

/* BOROS OVERVIEW (plain language)
 * This file is the thin Metal layer of surface building. Since 2026-11-26 (agent
 * "vulkan-engine", Vulkan plan 7.1 step 3) the GPU work itself - memory blocks, the
 * four GPU programs of BKSurfaceShaderSource.mm in the right order - lives in the
 * backend-neutral BKSurfacePass.cpp (shared with the Vulkan engine); this file compiles
 * the Metal programs, hands the scan texture to the pass and turns each result into a
 * BKMesh. All the thinking (grid size, memory checks, the marching-cubes table, adding
 * up row totals) lives in the plain-C core (BKSurfaceCore.c). Public API unchanged.
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
#import "BKMetalDevice.h"     // the user's chosen graphics card (Automatic by default)
#import <QuartzCore/QuartzCore.h>
#include "BKSurfacePass.h"     // the shared GPU flow (2026-11-26)
#include "BKGPUMetal.h"        // MetalDevice glue
#import "BKGPUEngineBridge.h"  // 2026-11-26: the Vulkan TEST engine (Boros 6 MoltenVK switch)
#include <vector>

extern "C" NSString *BKSurfaceShaderSource(void); // BKSurfaceShaderSource.mm

namespace bkgpu = boroskit::gpu;
namespace bksurface = boroskit::surface;

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
    std::unique_ptr<bkgpu::Device> _gpu;          // MetalDevice over _device + _commandQueue (2026-11-26)
    std::unique_ptr<bksurface::SurfacePass> _pass; // the shared surface flow (BKSurfacePass.h)
    // 2026-11-26: the same pass on the Vulkan TEST engine (BKGPUEngine.h); nullptr = Metal (default).
    bkgpu::Device *_vk;
    std::unique_ptr<bksurface::SurfacePass> _vkPass;
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
            library = [device newLibraryWithSource:BKSurfaceShaderSource() options:[BKMetalDevice shaderCompileOptions] /* fast math off, 2026-11-14 */ error:error];
            if (library) [cache setObject:library forKey:device];
        }
        return library;
    }
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    return [self initWithDevice:device commandQueue:nil error:error];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = device ?: [BKMetalDevice preferredDevice];   // no device given: the preferred card, see BKMetalDevice.h
    if (!_device) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusGPUFailed, @"No Metal GPU is available.", nil);
        return nil;
    }
    id<MTLLibrary> library = [[self class] libraryForDevice:_device error:error];
    if (!library) return nil;
    _commandQueue = commandQueue ?: [_device newCommandQueue];
    // The shared GPU interface on this device and queue; the pass makes its pipelines, sampler and table.
    if (!_commandQueue || bkgpu::makeMetalDevice(_device, _commandQueue, &_gpu) != bkgpu::Status::Ok ||
        bkgpu::BKGPUMetalAddLibrary(*_gpu, library) != bkgpu::Status::Ok) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusOutOfMemory, nil, nil);
        return nil;
    }
    _pass.reset(new bksurface::SurfacePass(*_gpu));
    BKSurfaceStatus status = _pass->prepare();
    if (status != BKSurfaceStatusOK) {
        if (error) *error = BKSurfaceError(status, @"(The surface GPU programs could not be prepared.)", nil);
        return nil;
    }
    // Vulkan TEST engine (only when the user chose it; else everything stays on Metal, as before).
    _vk = bkgpu::BKGPUTestEngineDevice();
    if (_vk) {
        std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
        _vkPass.reset(new bksurface::SurfacePass(*_vk));
        if (_vkPass->prepare() != BKSurfaceStatusOK) { _vkPass.reset(); _vk = nullptr; }
    }
    bkgpu::BKGPUEngineLogRenderer("BKSurfaceExtractor", _vk != nullptr);
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

- (BKMesh *)extractSurfaceFromVolume:(BKVolumeTexture *)volume threshold:(float)threshold
                          resolution:(float)resolution scanSmoothing:(float)scanSmoothing error:(NSError **)error
{
    BKSurfaceOptions *options = [[BKSurfaceOptions alloc] init];
    options.resolution = resolution;
    options.scanSmoothing = scanSmoothing;
    return [self extractSurfacesFromVolume:volume thresholds:@[@(threshold)] options:options timings:NULL error:error].firstObject;
}

// What the MeshSink of the pass needs: where to put the meshes, and the first BKMesh error.
struct BKSurfaceSinkContext {
    __unsafe_unretained NSMutableArray<BKMesh *> *meshes;
    NSError *error;
};

// What: one finished surface -> one BKMesh (a single copy). The GPU wrote 16 bytes per point
// (x, y, z, unused), which is exactly the memory layout of simd_float3, so no conversion is needed.
static BKSurfaceStatus BKSurfaceAddMesh(void *context, uint32_t, const bksurface::MeshView &view)
{
    BKSurfaceSinkContext *c = (BKSurfaceSinkContext *)context;
    if (view.triangleCount == 0) {   // nothing crosses the threshold: an empty mesh, not an error
        [c->meshes addObject:[[BKMesh alloc] init]];
        return BKSurfaceStatusOK;
    }
    NSError *error = nil;
    BKMesh *mesh = [[BKMesh alloc] initWithVertices:(const simd_float3 *)view.positions vertexCount:(NSUInteger)view.vertexCount
                                            indices:view.indices indexCount:(NSUInteger)view.triangleCount * 3
                                            normals:(const simd_float3 *)view.normals colors:NULL error:&error];
    if (!mesh) {
        c->error = error;
        return BKSurfaceStatusOutOfMemory;
    }
    [c->meshes addObject:mesh];
    return BKSurfaceStatusOK;
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

    // ---- The request for the plan (backend-neutral core) ----
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

    std::vector<float> steps;
    for (NSNumber *threshold in thresholds)
        steps.push_back(BKSurfaceThresholdToSteps(threshold.floatValue, volume.valueScale, volume.valueOffset));

    // ---- The shared GPU flow (sample / blur / classify / row sums / emit) ----
    if (_vk) {   // Vulkan TEST engine: the same pass on a cached copy of the scan; the meshes come out the same way
        std::lock_guard<std::recursive_mutex> lock(bkgpu::BKGPUTestEngineMutex());
        std::shared_ptr<bkgpu::Texture> vkScan = bkgpu::BKGPUCopyMetalTexture(*_vk, volume.texture, true);
        if (!vkScan) {
            if (error) *error = BKSurfaceError(BKSurfaceStatusGPUFailed, @"(Vulkan test engine: the scan could not be copied.)", nil);
            return nil;
        }
        NSMutableArray<BKMesh *> *meshes = [NSMutableArray array];
        BKSurfaceSinkContext sink = { meshes, nil };
        bksurface::Stats stats;
        double t0 = bkgpu::BKGPUEngineNowMs();
        BKSurfaceStatus status = _vkPass->extract(*vkScan, rq, steps.data(), (uint32_t)steps.size(), BKSurfaceAddMesh, &sink, &stats);
        if (status != BKSurfaceStatusOK) {
            if (error) *error = sink.error ?: BKSurfaceError(status, stats.detail ? @(stats.detail) : nil, nil);
            return nil;
        }
        bkgpu::BKGPUEngineLogFrame("BKSurfaceExtractor", stats.gridWidth, stats.gridHeight, bkgpu::BKGPUEngineNowMs() - t0);
        timings.gridWidth = stats.gridWidth; timings.gridHeight = stats.gridHeight; timings.gridDepth = stats.gridDepth;
        timings.samplingMilliseconds = stats.samplingMilliseconds;
        timings.extractionMilliseconds = stats.extractionMilliseconds;
        timings.meshMilliseconds = stats.sinkMilliseconds;
        timings.vertexCount = (NSUInteger)stats.vertexCount;
        timings.triangleCount = (NSUInteger)stats.triangleCount;
        timings.peakTemporaryBytes = (NSUInteger)stats.peakTemporaryBytes;
        timings.totalMilliseconds = BKNowMs() - tStart;
        @synchronized (self) { _lastTimings = timings.dictionaryRepresentation; }
        if (timingsOut) *timingsOut = timings;
        return meshes;
    }
    std::unique_ptr<bkgpu::Texture> scan = bkgpu::BKGPUMetalWrapTexture(*_gpu, volume.texture);
    if (!scan) {
        if (error) *error = BKSurfaceError(BKSurfaceStatusInvalidInput, @"(The scan texture has an unexpected format.)", nil);
        return nil;
    }
    NSMutableArray<BKMesh *> *meshes = [NSMutableArray array];
    BKSurfaceSinkContext sink = { meshes, nil };
    bksurface::Stats stats;
    BKSurfaceStatus status = _pass->extract(*scan, rq, steps.data(), (uint32_t)steps.size(), BKSurfaceAddMesh, &sink, &stats);
    if (status != BKSurfaceStatusOK) {
        if (error) *error = sink.error ?: BKSurfaceError(status, stats.detail ? @(stats.detail) : nil, nil);
        return nil;
    }

    timings.gridWidth = stats.gridWidth;
    timings.gridHeight = stats.gridHeight;
    timings.gridDepth = stats.gridDepth;
    timings.samplingMilliseconds = stats.samplingMilliseconds;
    timings.extractionMilliseconds = stats.extractionMilliseconds;
    timings.meshMilliseconds = stats.sinkMilliseconds;
    timings.vertexCount = (NSUInteger)stats.vertexCount;
    timings.triangleCount = (NSUInteger)stats.triangleCount;
    timings.peakTemporaryBytes = (NSUInteger)stats.peakTemporaryBytes;
    timings.totalMilliseconds = BKNowMs() - tStart;
    @synchronized (self) { _lastTimings = timings.dictionaryRepresentation; }
    if (timingsOut) *timingsOut = timings;
    return meshes;
}

@end
