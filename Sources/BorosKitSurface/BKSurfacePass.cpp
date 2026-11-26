// BorosKitSurface: BKSurfacePass.cpp - surface extraction on the shared GPU interface (see BKSurfacePass.h).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan 7.1 step 3). The flow is a one-to-one move of the Metal
// code that was in BKSurfaceExtractor.m (same buffers, same order, same command boundaries), so the Metal results
// stay bit-identical (golden strict).

#include "BKSurfacePass.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <vector>

namespace boroskit {
namespace surface {

using namespace boroskit::gpu;

namespace {

// What: milliseconds on a steady clock (for the timings only).
double NowMs()
{
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// The binding table every kernel declares (see the header: same numbers on Metal and Vulkan).
const SlotLayout kSlots[] = {
    { SlotKind::StorageBuffer, 0, false, false, false }, { SlotKind::StorageBuffer, 1, false, false, false },
    { SlotKind::StorageBuffer, 2, false, false, false }, { SlotKind::StorageBuffer, 3, false, false, false },
    { SlotKind::StorageBuffer, 4, false, false, false }, { SlotKind::StorageBuffer, 5, false, false, false },
    { SlotKind::StorageBuffer, 6, false, false, false }, { SlotKind::StorageBuffer, 7, false, false, false },
    { SlotKind::StorageBuffer, 8, false, false, false }, { SlotKind::SampledTexture, 0, false, false, false },
    { SlotKind::Sampler, 0, false, false, false },
};
const uint32_t kSlotCount = sizeof kSlots / sizeof kSlots[0];

// What: a compute pipeline with the first workgroup size in `sizes` (x, y, z triples) that the GPU accepts.
std::unique_ptr<ComputePipeline> MakeKernel(Device &device, const char *name, const uint32_t (*sizes)[3], uint32_t count,
                                            uint32_t chosen[3])
{
    for (uint32_t i = 0; i < count; i++) {
        ComputeDesc cd;
        cd.kernel.name = name;
        for (int a = 0; a < 3; a++) cd.workgroup[a] = sizes[i][a];
        cd.slots = kSlots;
        cd.slotCount = kSlotCount;
        cd.label = name;
        Status s = Status::Ok;
        std::unique_ptr<ComputePipeline> p = device.makeCompute(cd, &s);
        if (p) {
            for (int a = 0; a < 3; a++) chosen[a] = sizes[i][a];
            return p;
        }
        if (s != Status::Unsupported) return nullptr;   // a real failure (missing / broken kernel), not a size issue
    }
    return nullptr;
}

// What: one binding of a buffer / inline bytes / texture / sampler.
Binding BufferAt(uint32_t slot, Buffer *buffer)
{
    Binding b;
    b.kind = SlotKind::StorageBuffer;
    b.slot = slot;
    b.buffer = buffer;
    return b;
}

}  // namespace

struct SurfacePass::Impl {
    Device &device;
    std::unique_ptr<ComputePipeline> sample, blur, classify, emit;
    uint32_t pairsGroup[3] = { 1, 1, 1 };    // sample / blur workgroup
    uint32_t blurGroup[3] = { 1, 1, 1 };
    uint32_t classifyGroup[3] = { 1, 1, 1 }; // rows: x = threads along the row
    uint32_t emitGroup[3] = { 1, 1, 1 };
    std::unique_ptr<Sampler> linear;
    std::unique_ptr<Buffer> table;           // the generated marching-cubes table (read-only, shared by all calls)
    explicit Impl(Device &d) : device(d) {}

    // What: the dispatch over the "pairs" grid of sample and blur (one thread per two grid points along x).
    // Workgroup counts are rounded up; the kernels skip the extra threads.
    static void PairGroups(const BKSurfacePlan &plan, const uint32_t g[3], uint32_t out[3])
    {
        out[0] = (plan.rowStride / 2 + g[0] - 1) / g[0];
        out[1] = (plan.gridHeight + g[1] - 1) / g[1];
        out[2] = (plan.gridDepth + g[2] - 1) / g[2];
    }
};

SurfacePass::SurfacePass(Device &device) : impl_(new Impl(device)) {}
SurfacePass::~SurfacePass() = default;

BKSurfaceStatus SurfacePass::prepare()
{
    Impl &m = *impl_;
    if (m.sample) return BKSurfaceStatusOK;
    // Rows: an even power of two <= BK_SURFACE_ROW_THREADS (the scan arrays' size; pairs of 16-bit values).
    uint32_t rows[8][3];
    uint32_t rowCount = 0;
    for (uint32_t n = BK_SURFACE_ROW_THREADS; n >= 2 && rowCount < 8; n /= 2) { rows[rowCount][0] = n; rows[rowCount][1] = rows[rowCount][2] = 1; rowCount++; }
    // Pairs: 32 x 4 x 2 (the Metal choice for a 32-wide SIMD), shrunk in z then y if the GPU wants fewer.
    const uint32_t pairs[][3] = { { 32, 4, 2 }, { 32, 4, 1 }, { 32, 2, 1 }, { 32, 1, 1 }, { 16, 1, 1 }, { 8, 1, 1 }, { 1, 1, 1 } };
    m.sample = MakeKernel(m.device, "bk_surface_sample", pairs, 7, m.pairsGroup);
    m.blur = MakeKernel(m.device, "bk_surface_blur", pairs, 7, m.blurGroup);
    m.classify = MakeKernel(m.device, "bk_surface_classify", rows, rowCount, m.classifyGroup);
    m.emit = MakeKernel(m.device, "bk_surface_emit", rows, rowCount, m.emitGroup);
    if (!m.sample || !m.blur || !m.classify || !m.emit) {
        m.sample.reset();
        return BKSurfaceStatusGPUFailed;
    }
    SamplerDesc sd;
    sd.linear = true;
    sd.repeat = false;
    sd.normalizedCoordinates = true;
    m.linear = m.device.makeSampler(sd, nullptr);
    uint32_t words[BK_SURFACE_TABLE_WORDS];
    BKSurfaceFillGPUTable(words);
    m.table = m.device.makeBuffer(sizeof words, Memory::Upload, UsageStorage, nullptr);
    void *mapped = m.table ? m.table->map() : nullptr;
    if (!m.linear || !mapped) {
        m.sample.reset();
        return BKSurfaceStatusOutOfMemory;
    }
    std::memcpy(mapped, words, sizeof words);
    m.table->unmap();
    return BKSurfaceStatusOK;
}

BKSurfaceStatus SurfacePass::extract(Texture &volume, const BKSurfacePlanRequest &request, const float *thresholdSteps,
                                     uint32_t thresholdCount, MeshSink sink, void *context, Stats *statsOut)
{
    Impl &m = *impl_;
    Stats localStats;
    Stats &stats = statsOut ? *statsOut : localStats;
    stats = Stats();
    if (!m.sample) return BKSurfaceStatusGPUFailed;   // prepare() missing or failed
    if (!thresholdSteps || thresholdCount == 0 || !sink) return BKSurfaceStatusInvalidInput;
    Device &device = m.device;
    const Limits &limits = device.limits();

    // ---- 1. Plan (backend-neutral core) ----
    BKSurfacePlanRequest rq = request;
    if (!rq.maxBufferBytes) rq.maxBufferBytes = limits.maxBufferBytes;
    if (!rq.memoryBudgetBytes) rq.memoryBudgetBytes = limits.memoryBudgetBytes;
    BKSurfacePlan plan;
    BKSurfaceStatus status = BKSurfacePlanMake(&rq, &plan);
    if (status != BKSurfaceStatusOK) return status;
    stats.gridWidth = plan.gridWidth;
    stats.gridHeight = plan.gridHeight;
    stats.gridDepth = plan.gridDepth;
    for (uint32_t i = 0; i < thresholdCount; i++)
        if (std::isnan(thresholdSteps[i])) {
            stats.detail = "(The threshold is not a number.)";
            return BKSurfaceStatusInvalidInput;
        }

    Binding params;
    params.kind = SlotKind::StorageBuffer;
    params.slot = 0;
    params.byteCount = sizeof(BKSurfaceParams);
    Binding tex;
    tex.kind = SlotKind::SampledTexture;
    tex.slot = 0;
    tex.texture = &volume;
    Binding smp;
    smp.kind = SlotKind::Sampler;
    smp.slot = 0;
    smp.sampler = m.linear.get();

    // ---- 2. Working copy of the scan (only when resampling or smoothing); GPU-only memory ----
    std::unique_ptr<Buffer> field;
    uint64_t peakBytes = 0;
    if (plan.usesField) {
        const double t0 = NowMs();
        field = device.makeBuffer(plan.fieldBytes, Memory::DeviceOnly, UsageStorage, nullptr);
        std::unique_ptr<Buffer> spare = plan.blurs ? device.makeBuffer(plan.fieldBytes, Memory::DeviceOnly, UsageStorage, nullptr) : nullptr;
        if (!field || (plan.blurs && !spare)) return BKSurfaceStatusOutOfMemory;
        peakBytes = plan.fieldBytes * (plan.blurs ? 2 : 1);
        std::unique_ptr<CommandList> list = device.begin(nullptr);
        if (!list) return BKSurfaceStatusOutOfMemory;
        BKSurfaceParams p = plan.params;
        params.bytes = &p;
        uint32_t groups[3];
        Impl::PairGroups(plan, m.pairsGroup, groups);
        Binding sb[4] = { params, BufferAt(1, field.get()), tex, smp };
        if (list->dispatch(*m.sample, sb, 4, groups[0], groups[1], groups[2]) != Status::Ok) return BKSurfaceStatusGPUFailed;
        // Separable blur: x, y, z, each from one buffer into the other (the interface orders the dispatches;
        // inline bytes are copied when recorded, so `p` can change between them).
        Impl::PairGroups(plan, m.blurGroup, groups);
        for (uint32_t axis = 0; axis < 3; axis++) {
            if (!plan.blurRadius[axis]) continue;
            BKSurfacePlanSetBlurAxis(&plan, axis, &p);
            Binding bb[5] = { params, BufferAt(1, field.get()), BufferAt(2, spare.get()), tex, smp };
            if (list->dispatch(*m.blur, bb, 5, groups[0], groups[1], groups[2]) != Status::Ok) return BKSurfaceStatusGPUFailed;
            std::swap(field, spare);   // the blurred copy becomes the field
        }
        if (device.submit(*list, true) != Status::Ok) return BKSurfaceStatusGPUFailed;
        list.reset();
        spare.reset();   // freed here, before the extraction buffers are made
        stats.samplingMilliseconds = NowMs() - t0;
    }

    // ---- 3. Per threshold: classify -> row prefix sum (CPU) -> emit -> MeshSink ----
    const double tExtract = NowMs();
    double sinkMs = 0;
    std::unique_ptr<Buffer> packed = device.makeBuffer(plan.packedBytes, Memory::DeviceOnly, UsageStorage, nullptr);
    std::unique_ptr<Buffer> rowVertices = device.makeBuffer(plan.rowTableBytes, Memory::Readback, UsageStorage, nullptr);
    std::unique_ptr<Buffer> rowTriangles = device.makeBuffer(plan.rowTableBytes, Memory::Readback, UsageStorage, nullptr);
    std::unique_ptr<Buffer> dummy = field ? nullptr : device.makeBuffer(16, Memory::DeviceOnly, UsageStorage, nullptr);   // unused when reading the texture
    Buffer *fieldOrDummy = field ? field.get() : dummy.get();
    if (!packed || !rowVertices || !rowTriangles || !fieldOrDummy) return BKSurfaceStatusOutOfMemory;
    const uint64_t workingBytes = plan.fieldBytes + plan.packedBytes + 2 * plan.rowTableBytes;
    if (workingBytes > peakBytes) peakBytes = workingBytes;

    uint64_t totalVertices = 0, totalTriangles = 0;
    for (uint32_t t = 0; t < thresholdCount; t++) {
        BKSurfaceParams p = plan.params;
        p.thresholdSteps = thresholdSteps[t];
        params.bytes = &p;

        // a) classify every row (one workgroup per row: grid y, grid z)
        std::unique_ptr<CommandList> list = device.begin(nullptr);
        if (!list) return BKSurfaceStatusOutOfMemory;
        Binding cb[8] = { params, BufferAt(1, fieldOrDummy), BufferAt(2, packed.get()), BufferAt(3, rowVertices.get()),
                          BufferAt(4, rowTriangles.get()), BufferAt(5, m.table.get()), tex, smp };
        if (list->dispatch(*m.classify, cb, 8, plan.gridHeight, plan.gridDepth, 1) != Status::Ok ||
            device.submit(*list, true) != Status::Ok)
            return BKSurfaceStatusGPUFailed;
        list.reset();

        // b) row counts -> row starts (CPU, on the readable memory the GPU just wrote)
        uint32_t *rv = (uint32_t *)rowVertices->map(), *rt = (uint32_t *)rowTriangles->map();
        if (!rv || !rt) return BKSurfaceStatusGPUFailed;
        uint64_t vertexCount = BKSurfaceExclusiveScan(rv, plan.rowCount);
        uint64_t triangleCount = BKSurfaceExclusiveScan(rt, plan.rowCount);
        rowVertices->unmap();
        rowTriangles->unmap();
        if (vertexCount == UINT64_MAX || triangleCount == UINT64_MAX || triangleCount * 3 > UINT32_MAX) return BKSurfaceStatusTooLarge;
        if (triangleCount == 0) {   // nothing crosses the threshold: an empty mesh, not an error
            const double ts = NowMs();
            BKSurfaceStatus s = sink(context, t, MeshView());
            sinkMs += NowMs() - ts;
            if (s != BKSurfaceStatusOK) return s;
            continue;
        }

        // c) exact-size result buffers (readable: the caller copies them into its mesh)
        const uint64_t outBytes = BKSurfaceOutputBytes(vertexCount, triangleCount);
        if (vertexCount * 16 > rq.maxBufferBytes || triangleCount * 12 > rq.maxBufferBytes ||
            (rq.memoryBudgetBytes && workingBytes + outBytes > rq.memoryBudgetBytes))
            return BKSurfaceStatusTooLarge;
        std::unique_ptr<Buffer> positions = device.makeBuffer(vertexCount * 16, Memory::Readback, UsageStorage, nullptr);
        std::unique_ptr<Buffer> normals = device.makeBuffer(vertexCount * 16, Memory::Readback, UsageStorage, nullptr);
        std::unique_ptr<Buffer> indices = device.makeBuffer(triangleCount * 12, Memory::Readback, UsageStorage, nullptr);
        if (!positions || !normals || !indices) return BKSurfaceStatusOutOfMemory;
        if (workingBytes + outBytes > peakBytes) peakBytes = workingBytes + outBytes;

        // d) emit vertices and triangles
        list = device.begin(nullptr);
        if (!list) return BKSurfaceStatusOutOfMemory;
        Binding eb[11] = { params, BufferAt(1, fieldOrDummy), BufferAt(2, packed.get()), BufferAt(3, rowVertices.get()),
                           BufferAt(4, rowTriangles.get()), BufferAt(5, m.table.get()), BufferAt(6, positions.get()),
                           BufferAt(7, normals.get()), BufferAt(8, indices.get()), tex, smp };
        if (list->dispatch(*m.emit, eb, 11, plan.gridHeight, plan.gridDepth, 1) != Status::Ok ||
            device.submit(*list, true) != Status::Ok)
            return BKSurfaceStatusGPUFailed;
        list.reset();

        // e) hand the surface to the caller
        MeshView view;
        view.positions = (const float *)positions->map();
        view.normals = (const float *)normals->map();
        view.indices = (const uint32_t *)indices->map();
        view.vertexCount = vertexCount;
        view.triangleCount = triangleCount;
        if (!view.positions || !view.normals || !view.indices) return BKSurfaceStatusGPUFailed;
        const double ts = NowMs();
        BKSurfaceStatus s = sink(context, t, view);
        sinkMs += NowMs() - ts;
        positions->unmap();
        normals->unmap();
        indices->unmap();
        if (s != BKSurfaceStatusOK) return s;
        totalVertices += vertexCount;
        totalTriangles += triangleCount;
    }
    stats.extractionMilliseconds = NowMs() - tExtract - sinkMs;
    stats.sinkMilliseconds = sinkMs;
    stats.vertexCount = totalVertices;
    stats.triangleCount = totalTriangles;
    stats.peakTemporaryBytes = peakBytes;
    return BKSurfaceStatusOK;
}

}  // namespace surface
}  // namespace boroskit
