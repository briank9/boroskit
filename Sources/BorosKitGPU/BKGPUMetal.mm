// BorosKitGPU: BKGPUMetal - the Metal implementation of the BKGPU.h interface (see BKGPUMetal.h).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (Vulkan plan phase 2). Objective-C++, ARC.
//
// Every mapping reproduces what BorosKit's hand-written Metal code did, so passes built on the interface draw the
// same pixels (strict golden). Compute pipelines + dispatch since 2026-11-26 (phase 3/4).

#import "BKGPUMetal.h"

#include <map>
#include <string>
#include <vector>

namespace boroskit {
namespace gpu {

namespace {

// ---- Formats ---------------------------------------------------------------------------------------------------

MTLPixelFormat ToMetal(Format f)
{
    switch (f) {
        case Format::R8Unorm: return MTLPixelFormatR8Unorm;
        case Format::R16Unorm: return MTLPixelFormatR16Unorm;
        case Format::R32Float: return MTLPixelFormatR32Float;
        case Format::R32Uint: return MTLPixelFormatR32Uint;
        case Format::RGBA8Unorm: return MTLPixelFormatRGBA8Unorm;
        case Format::BGRA8Unorm: return MTLPixelFormatBGRA8Unorm;
        case Format::RGBA16Float: return MTLPixelFormatRGBA16Float;
        case Format::RGBA32Float: return MTLPixelFormatRGBA32Float;
        case Format::Depth32Float: return MTLPixelFormatDepth32Float;
    }
    return MTLPixelFormatInvalid;
}

bool FromMetal(MTLPixelFormat m, Format *out)
{
    const Format all[] = { Format::R8Unorm, Format::R16Unorm, Format::R32Float, Format::R32Uint, Format::RGBA8Unorm,
                           Format::BGRA8Unorm, Format::RGBA16Float, Format::RGBA32Float, Format::Depth32Float };
    for (Format f : all) if (ToMetal(f) == m) { *out = f; return true; }
    return false;
}

uint32_t BytesPerTexel(Format f)
{
    switch (f) {
        case Format::R8Unorm: return 1;
        case Format::R16Unorm: return 2;
        case Format::RGBA16Float: return 8;
        case Format::RGBA32Float: return 16;
        default: return 4;
    }
}

void Set(Status *s, Status v) { if (s) *s = v; }

// ---- Resources -------------------------------------------------------------------------------------------------

class MetalBuffer final : public Buffer {
public:
    explicit MetalBuffer(id<MTLBuffer> b) : buffer(b) {}
    uint64_t size() const override { return buffer.length; }
    void *map() override { return buffer.storageMode == MTLStorageModePrivate ? nullptr : buffer.contents; }
    void unmap() override {}
    id<MTLBuffer> buffer;
};

class MetalTexture final : public Texture {
public:
    MetalTexture(id<MTLTexture> t, const TextureDesc &d) : texture(t), desc_(d) {}
    const TextureDesc &desc() const override { return desc_; }
    id<MTLTexture> texture;
    TextureDesc desc_;
};

class MetalSampler final : public Sampler {
public:
    explicit MetalSampler(id<MTLSamplerState> s) : sampler(s) {}
    id<MTLSamplerState> sampler;
};

class MetalComputePipeline final : public ComputePipeline {
public:
    id<MTLComputePipelineState> state;
    MTLSize workgroup;
    std::vector<SlotLayout> slots;
};

class MetalRenderPipeline final : public RenderPipeline {
public:
    id<MTLRenderPipelineState> state;
    id<MTLDepthStencilState> depthState;
    MTLCullMode cull = MTLCullModeNone;
    MTLTriangleFillMode fill = MTLTriangleFillModeFill;
    std::vector<SlotLayout> slots;
};

// What: the device-wide parts every MetalCommandList needs.
struct MetalShared {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
};

// ---- Recording ---------------------------------------------------------------------------------------------------

class MetalCommandList final : public CommandList {
public:
    MetalCommandList(MetalShared *shared, id<MTLCommandBuffer> cb, bool external) : shared_(shared), cb_(cb), external_(external) {}
    ~MetalCommandList() override { endBlit(); endCompute(); endPass(); }

    id<MTLCommandBuffer> commandBuffer() const { return cb_; }
    bool external() const { return external_; }

    Status upload(Texture &texture, const void *data, uint32_t rowBytes, uint32_t sliceBytes, uint32_t firstSlice,
                  uint32_t sliceCount) override
    {
        if (render_ || !data) return Status::InvalidArgument;
        MetalTexture &t = static_cast<MetalTexture &>(texture);
        const TextureDesc &d = t.desc();
        uint32_t tight = d.width * BytesPerTexel(d.format);
        if (rowBytes < tight || sliceBytes < rowBytes * d.height || firstSlice + sliceCount > d.depth) return Status::InvalidArgument;
        id<MTLBuffer> staging = [shared_->device newBufferWithLength:(NSUInteger)tight * d.height * sliceCount options:MTLResourceStorageModeShared];
        if (!staging) return Status::OutOfMemory;
        uint8_t *dst = (uint8_t *)staging.contents;
        for (uint32_t z = 0; z < sliceCount; z++)
            for (uint32_t y = 0; y < d.height; y++)
                memcpy(dst + ((size_t)z * d.height + y) * tight, (const uint8_t *)data + (size_t)z * sliceBytes + (size_t)y * rowBytes, tight);
        [blit() copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:tight sourceBytesPerImage:(NSUInteger)tight * d.height
                    sourceSize:MTLSizeMake(d.width, d.height, sliceCount) toTexture:t.texture destinationSlice:0
              destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, firstSlice)];
        return Status::Ok;
    }

    Status upload(Buffer &buffer, uint64_t offset, const void *data, uint64_t bytes) override
    {
        MetalBuffer &b = static_cast<MetalBuffer &>(buffer);
        if (render_ || !data || offset + bytes > b.size()) return Status::InvalidArgument;
        id<MTLBuffer> staging = [shared_->device newBufferWithBytes:data length:(NSUInteger)bytes options:MTLResourceStorageModeShared];
        if (!staging) return Status::OutOfMemory;
        [blit() copyFromBuffer:staging sourceOffset:0 toBuffer:b.buffer destinationOffset:(NSUInteger)offset size:(NSUInteger)bytes];
        return Status::Ok;
    }

    Status readback(Texture &texture, Buffer &destination) override
    {
        MetalTexture &t = static_cast<MetalTexture &>(texture);
        MetalBuffer &b = static_cast<MetalBuffer &>(destination);
        const TextureDesc &d = t.desc();
        uint32_t row = d.width * BytesPerTexel(d.format);
        if (render_ || (uint64_t)row * d.height * d.depth > b.size()) return Status::InvalidArgument;
        [blit() copyFromTexture:t.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(d.width, d.height, d.depth) toBuffer:b.buffer destinationOffset:0
         destinationBytesPerRow:row destinationBytesPerImage:(NSUInteger)row * d.height];
        return Status::Ok;
    }

    Status copy(Buffer &source, uint64_t sourceOffset, Buffer &destination, uint64_t destinationOffset, uint64_t bytes) override
    {
        if (render_) return Status::InvalidArgument;
        [blit() copyFromBuffer:static_cast<MetalBuffer &>(source).buffer sourceOffset:(NSUInteger)sourceOffset
                      toBuffer:static_cast<MetalBuffer &>(destination).buffer destinationOffset:(NSUInteger)destinationOffset
                          size:(NSUInteger)bytes];
        return Status::Ok;
    }

    // Compute (2026-11-26): consecutive dispatches share one compute encoder; Metal orders them and tracks the
    // hazards between them (the resources are hazard-tracked), so no explicit barrier is needed.
    Status dispatch(ComputePipeline &pipeline, const Binding *bindings, uint32_t bindingCount,
                    uint32_t groupsX, uint32_t groupsY, uint32_t groupsZ) override
    {
        if (render_) return Status::InvalidArgument;
        endBlit();
        if (!compute_) compute_ = [cb_ computeCommandEncoder];
        if (!compute_) return Status::OutOfMemory;
        MetalComputePipeline &p = static_cast<MetalComputePipeline &>(pipeline);
        [compute_ setComputePipelineState:p.state];
        for (uint32_t i = 0; i < bindingCount; i++) {
            const Binding &b = bindings[i];
            switch (b.kind) {
                case SlotKind::UniformBlock:
                case SlotKind::StorageBuffer:
                    if (b.bytes) {
                        if (b.byteCount == 0 || b.byteCount > kMaxInlineBytes) return Status::InvalidArgument;
                        [compute_ setBytes:b.bytes length:b.byteCount atIndex:b.slot];
                    } else if (b.buffer) {
                        [compute_ setBuffer:static_cast<MetalBuffer *>(b.buffer)->buffer offset:(NSUInteger)b.offset atIndex:b.slot];
                    } else return Status::InvalidArgument;
                    break;
                case SlotKind::SampledTexture:
                case SlotKind::StorageImage:
                    if (!b.texture) return Status::InvalidArgument;
                    [compute_ setTexture:static_cast<MetalTexture *>(b.texture)->texture atIndex:b.slot];
                    break;
                case SlotKind::Sampler:
                    if (!b.sampler) return Status::InvalidArgument;
                    [compute_ setSamplerState:static_cast<MetalSampler *>(b.sampler)->sampler atIndex:b.slot];
                    break;
            }
        }
        [compute_ dispatchThreadgroups:MTLSizeMake(groupsX, groupsY, groupsZ) threadsPerThreadgroup:p.workgroup];
        return Status::Ok;
    }

    // A render pass exactly like the hand-written mesh renderer's: colour targets cleared or kept, depth cleared to
    // clearDepth and not stored, viewport = scissor = the drawing area, no culling, counter-clockwise front faces.
    Status beginPass(const PassTargets &targets) override
    {
        if (render_ || targets.colorCount > 2 || (targets.colorCount == 0 && !targets.depth)) return Status::InvalidArgument;
        endBlit();
        endCompute();
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        NSUInteger width = 0, height = 0;
        for (uint32_t i = 0; i < targets.colorCount; i++) {
            MetalTexture *t = static_cast<MetalTexture *>(targets.color[i]);
            if (!t) return Status::InvalidArgument;
            pass.colorAttachments[i].texture = t->texture;
            pass.colorAttachments[i].loadAction = targets.clearColor[i] ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.colorAttachments[i].clearColor = MTLClearColorMake(targets.clearValue[i][0], targets.clearValue[i][1],
                                                                    targets.clearValue[i][2], targets.clearValue[i][3]);
            pass.colorAttachments[i].storeAction = MTLStoreActionStore;
            width = t->texture.width;
            height = t->texture.height;
        }
        if (targets.depth) {
            MetalTexture *t = static_cast<MetalTexture *>(targets.depth);
            pass.depthAttachment.texture = t->texture;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.clearDepth = targets.clearDepth;
            pass.depthAttachment.storeAction = MTLStoreActionDontCare;
            if (!width) { width = t->texture.width; height = t->texture.height; }
        }
        render_ = [cb_ renderCommandEncoderWithDescriptor:pass];
        if (!render_) return Status::OutOfMemory;
        render_.label = @"BorosKit pass";
        [render_ setCullMode:MTLCullModeNone];
        [render_ setFrontFacingWinding:MTLWindingCounterClockwise];   // BKMeshDrawCore.h: CCW with y up = front
        int32_t vx = targets.viewport[0], vy = targets.viewport[1], vw = targets.viewport[2], vh = targets.viewport[3];
        if (vw <= 0 || vh <= 0) { vx = 0; vy = 0; vw = (int32_t)width; vh = (int32_t)height; }
        [render_ setViewport:(MTLViewport){ (double)vx, (double)vy, (double)vw, (double)vh, 0.0, 1.0 }];
        setScissor(vx, vy, vw, vh);
        return Status::Ok;
    }

    void setScissor(int32_t x, int32_t y, int32_t width, int32_t height) override
    {
        if (!render_) return;
        [render_ setScissorRect:(MTLScissorRect){ (NSUInteger)MAX(x, 0), (NSUInteger)MAX(y, 0), (NSUInteger)MAX(width, 0), (NSUInteger)MAX(height, 0) }];
    }

    Status draw(RenderPipeline &pipeline, const Binding *bindings, uint32_t bindingCount, uint32_t vertexCount,
                uint32_t firstVertex, Buffer *indices, uint32_t indexCount) override
    {
        if (!render_) return Status::InvalidArgument;
        MetalRenderPipeline &p = static_cast<MetalRenderPipeline &>(pipeline);
        [render_ setRenderPipelineState:p.state];
        [render_ setDepthStencilState:p.depthState];
        [render_ setCullMode:p.cull];
        [render_ setTriangleFillMode:p.fill];
        for (uint32_t i = 0; i < bindingCount; i++) {
            const Binding &b = bindings[i];
            bool vertex = false, fragment = false;   // the stages the pipeline's slot list names for this slot
            for (const SlotLayout &s : p.slots)
                if (s.kind == b.kind && s.slot == b.slot) { vertex = s.vertexStage; fragment = s.fragmentStage; }
            if (!vertex && !fragment) return Status::InvalidArgument;
            switch (b.kind) {
                case SlotKind::UniformBlock:
                case SlotKind::StorageBuffer:
                    if (b.bytes) {
                        if (b.byteCount == 0 || b.byteCount > kMaxInlineBytes) return Status::InvalidArgument;
                        if (vertex) [render_ setVertexBytes:b.bytes length:b.byteCount atIndex:b.slot];
                        if (fragment) [render_ setFragmentBytes:b.bytes length:b.byteCount atIndex:b.slot];
                    } else if (b.buffer) {
                        id<MTLBuffer> mb = static_cast<MetalBuffer *>(b.buffer)->buffer;
                        if (vertex) [render_ setVertexBuffer:mb offset:(NSUInteger)b.offset atIndex:b.slot];
                        if (fragment) [render_ setFragmentBuffer:mb offset:(NSUInteger)b.offset atIndex:b.slot];
                    } else return Status::InvalidArgument;
                    break;
                case SlotKind::SampledTexture:
                case SlotKind::StorageImage: {
                    if (!b.texture) return Status::InvalidArgument;
                    id<MTLTexture> t = static_cast<MetalTexture *>(b.texture)->texture;
                    if (vertex) [render_ setVertexTexture:t atIndex:b.slot];
                    if (fragment) [render_ setFragmentTexture:t atIndex:b.slot];
                    break;
                }
                case SlotKind::Sampler: {
                    if (!b.sampler) return Status::InvalidArgument;
                    id<MTLSamplerState> s = static_cast<MetalSampler *>(b.sampler)->sampler;
                    if (vertex) [render_ setVertexSamplerState:s atIndex:b.slot];
                    if (fragment) [render_ setFragmentSamplerState:s atIndex:b.slot];
                    break;
                }
            }
        }
        if (indices)
            [render_ drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:indexCount indexType:MTLIndexTypeUInt32
                               indexBuffer:static_cast<MetalBuffer *>(indices)->buffer indexBufferOffset:0];
        else
            [render_ drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:firstVertex vertexCount:vertexCount];
        return Status::Ok;
    }

    void endPass() override
    {
        if (render_) { [render_ endEncoding]; render_ = nil; }
    }

    void timestamp(uint32_t) override {}

    void finish() { endBlit(); endCompute(); endPass(); }

private:
    id<MTLBlitCommandEncoder> blit()
    {
        endCompute();
        if (!blit_) blit_ = [cb_ blitCommandEncoder];
        return blit_;
    }
    void endBlit()
    {
        if (blit_) { [blit_ endEncoding]; blit_ = nil; }
    }
    void endCompute()
    {
        if (compute_) { [compute_ endEncoding]; compute_ = nil; }
    }

    MetalShared *shared_;
    id<MTLCommandBuffer> cb_;
    bool external_;
    id<MTLRenderCommandEncoder> render_;
    id<MTLBlitCommandEncoder> blit_;
    id<MTLComputeCommandEncoder> compute_;
};

// ---- The device ---------------------------------------------------------------------------------------------------

class MetalDevice final : public Device {
public:
    explicit MetalDevice(id<MTLDevice> device, id<MTLCommandQueue> queue = nil)
    {
        shared_.device = device;
        shared_.queue = queue ?: [device newCommandQueue];   // a caller's queue (2026-11-26: BKSurfaceExtractor)
        name_ = device.name.UTF8String ?: "";
        limits_.maxBufferBytes = device.maxBufferLength;
        limits_.maxStorageBufferRange = device.maxBufferLength;
        limits_.memoryBudgetBytes = device.recommendedMaxWorkingSetSize;
        limits_.maxImage2D = 16384;
        limits_.maxImage3D = 2048;
        limits_.maxComputeWorkgroupInvocations = 1024;
        limits_.maxComputeWorkgroupSize[0] = limits_.maxComputeWorkgroupSize[1] = limits_.maxComputeWorkgroupSize[2] = 1024;
        limits_.maxComputeSharedBytes = (uint32_t)device.maxThreadgroupMemoryLength;
        limits_.maxPushConstantBytes = 4096;   // setBytes limit
        limits_.linearFilterR16Unorm3D = true;
        limits_.linearFilterRGBA32Float = device.supports32BitFloatFiltering;
        limits_.linearFilterR32Float = device.supports32BitFloatFiltering;
        limits_.depth32Float = true;
        limits_.independentBlend = true;
        limits_.wireframe = true;
        limits_.unifiedMemory = device.hasUnifiedMemory;
        limits_.timestamps = false;
    }

    const Limits &limits() const override { return limits_; }
    const char *name() const override { return name_.c_str(); }
    id<MTLDevice> mtlDevice() const { return shared_.device; }

    void addLibrary(id<MTLLibrary> library) { if (library) libraries_.push_back(library); }

    std::unique_ptr<Buffer> makeBuffer(uint64_t bytes, Memory memory, uint32_t, Status *status) override
    {
        if (bytes == 0) { Set(status, Status::InvalidArgument); return nullptr; }
        MTLResourceOptions options = memory == Memory::DeviceOnly ? MTLResourceStorageModePrivate : MTLResourceStorageModeShared;
        id<MTLBuffer> b = [shared_.device newBufferWithLength:(NSUInteger)bytes options:options];
        if (!b) { Set(status, Status::OutOfMemory); return nullptr; }
        Set(status, Status::Ok);
        return std::unique_ptr<Buffer>(new MetalBuffer(b));
    }

    std::unique_ptr<Texture> makeTexture(const TextureDesc &desc, Status *status) override
    {
        bool is3D = desc.type == TextureType::Texture3D;
        if (desc.width == 0 || desc.height == 0 || desc.depth == 0 || (!is3D && desc.depth != 1)) {
            Set(status, Status::InvalidArgument);
            return nullptr;
        }
        MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
        d.textureType = is3D ? MTLTextureType3D : MTLTextureType2D;
        d.pixelFormat = ToMetal(desc.format);
        d.width = desc.width;
        d.height = desc.height;
        d.depth = desc.depth;
        d.mipmapLevelCount = 1;
        d.storageMode = MTLStorageModePrivate;
        MTLTextureUsage usage = 0;
        if (desc.usage & UsageSampled) usage |= MTLTextureUsageShaderRead;
        if (desc.usage & UsageStorage) usage |= MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        if (desc.usage & (UsageRenderTarget | UsageDepthTarget)) usage |= MTLTextureUsageRenderTarget;
        if (desc.format == Format::Depth32Float) usage |= MTLTextureUsageRenderTarget;
        d.usage = usage;
        id<MTLTexture> t = [shared_.device newTextureWithDescriptor:d];
        if (!t) { Set(status, Status::OutOfMemory); return nullptr; }
        if (desc.label) t.label = [NSString stringWithUTF8String:desc.label];
        Set(status, Status::Ok);
        return std::unique_ptr<Texture>(new MetalTexture(t, desc));
    }

    std::unique_ptr<Sampler> makeSampler(const SamplerDesc &desc, Status *status) override
    {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = sd.magFilter = desc.linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = desc.repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sd.normalizedCoordinates = desc.normalizedCoordinates;
        id<MTLSamplerState> s = [shared_.device newSamplerStateWithDescriptor:sd];
        if (!s) { Set(status, Status::OutOfMemory); return nullptr; }
        Set(status, Status::Ok);
        return std::unique_ptr<Sampler>(new MetalSampler(s));
    }

    std::unique_ptr<ComputePipeline> makeCompute(const ComputeDesc &desc, Status *status) override
    {
        id<MTLFunction> kernel = function(desc.kernel.name);
        if (!kernel) { Set(status, Status::NotFound); return nullptr; }
        NSError *error = nil;
        id<MTLComputePipelineState> state = [shared_.device newComputePipelineStateWithFunction:kernel error:&error];
        if (!state) {
            NSLog(@"BorosKit MetalDevice: compute pipeline %s failed: %@", desc.kernel.name, error);
            Set(status, Status::CompileFailed);
            return nullptr;
        }
        uint64_t threads = (uint64_t)desc.workgroup[0] * desc.workgroup[1] * desc.workgroup[2];
        if (threads == 0 || threads > state.maxTotalThreadsPerThreadgroup) { Set(status, Status::Unsupported); return nullptr; }
        std::unique_ptr<MetalComputePipeline> p(new MetalComputePipeline());
        p->state = state;
        p->workgroup = MTLSizeMake(desc.workgroup[0], desc.workgroup[1], desc.workgroup[2]);
        p->slots.assign(desc.slots, desc.slots + desc.slotCount);
        Set(status, Status::Ok);
        return std::unique_ptr<ComputePipeline>(p.release());
    }

    std::unique_ptr<RenderPipeline> makeRender(const RenderDesc &desc, Status *status) override
    {
        if (desc.colorCount > 2) { Set(status, Status::InvalidArgument); return nullptr; }
        id<MTLFunction> vertex = function(desc.vertex.name), fragment = function(desc.fragment.name);
        if (!vertex || !fragment) { Set(status, Status::NotFound); return nullptr; }
        // The colour state as the hand-written renderers set it: premultiplied "over" = source one, destination
        // one-minus-source-alpha for colour and alpha; write mask all or none.
        MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction = vertex;
        d.fragmentFunction = fragment;
        for (uint32_t i = 0; i < desc.colorCount; i++) {
            const ColorTarget &t = desc.color[i];
            d.colorAttachments[i].pixelFormat = ToMetal(t.format);
            if (t.premultipliedOver) {
                d.colorAttachments[i].blendingEnabled = YES;
                d.colorAttachments[i].sourceRGBBlendFactor = MTLBlendFactorOne;
                d.colorAttachments[i].sourceAlphaBlendFactor = MTLBlendFactorOne;
                d.colorAttachments[i].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                d.colorAttachments[i].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }
            if (!t.writeEnabled) d.colorAttachments[i].writeMask = MTLColorWriteMaskNone;
        }
        if (desc.hasDepth) d.depthAttachmentPixelFormat = ToMetal(desc.depthFormat);
        std::unique_ptr<MetalRenderPipeline> p(new MetalRenderPipeline());
        p->state = pipelineState(d, desc);
        if (!p->state) { Set(status, Status::CompileFailed); return nullptr; }
        MTLDepthStencilDescriptor *ds = [[MTLDepthStencilDescriptor alloc] init];
        ds.depthCompareFunction = !desc.hasDepth ? MTLCompareFunctionAlways
                                : desc.depthCompare == DepthCompare::Less ? MTLCompareFunctionLess
                                : desc.depthCompare == DepthCompare::LessOrEqual ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways;
        ds.depthWriteEnabled = desc.hasDepth && desc.depthWrite;
        p->depthState = [shared_.device newDepthStencilStateWithDescriptor:ds];
        p->cull = desc.cull == CullMode::Back ? MTLCullModeBack : (desc.cull == CullMode::Front ? MTLCullModeFront : MTLCullModeNone);
        p->fill = desc.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        p->slots.assign(desc.slots, desc.slots + desc.slotCount);
        Set(status, Status::Ok);
        return std::unique_ptr<RenderPipeline>(p.release());
    }

    std::unique_ptr<CommandList> begin(Status *status) override
    {
        id<MTLCommandBuffer> cb = [shared_.queue commandBuffer];
        if (!cb) { Set(status, Status::OutOfMemory); return nullptr; }
        Set(status, Status::Ok);
        return std::unique_ptr<CommandList>(new MetalCommandList(&shared_, cb, false));
    }

    Status submit(CommandList &work, bool wait, void (*done)(void *, Status), void *context) override
    {
        MetalCommandList &list = static_cast<MetalCommandList &>(work);
        if (list.external()) return Status::InvalidArgument;   // the owner of a wrapped command buffer commits it
        list.finish();
        id<MTLCommandBuffer> cb = list.commandBuffer();
        if (done && !wait) {
            [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { done(context, b.status == MTLCommandBufferStatusError ? Status::DeviceLost : Status::Ok); }];
        }
        [cb commit];
        if (!wait) return Status::Ok;
        [cb waitUntilCompleted];
        Status s = cb.status == MTLCommandBufferStatusError ? Status::DeviceLost : Status::Ok;
        if (done) done(context, s);
        return s;
    }

    MetalShared *shared() { return &shared_; }

private:
    id<MTLFunction> function(const char *name)
    {
        if (!name) return nil;
        NSString *n = [NSString stringWithUTF8String:name];
        for (id<MTLLibrary> lib : libraries_) {
            id<MTLFunction> f = [lib newFunctionWithName:n];
            if (f) return f;
        }
        return nil;
    }

    // Identical descriptors share one pipeline state (a RenderDesc that differs only in depth / cull / fill state,
    // which Metal keeps on the encoder, does not compile a second time).
    id<MTLRenderPipelineState> pipelineState(MTLRenderPipelineDescriptor *d, const RenderDesc &desc)
    {
        std::string key = std::string(desc.vertex.name) + "|" + desc.fragment.name + "|" + std::to_string(desc.colorCount);
        for (uint32_t i = 0; i < desc.colorCount; i++)
            key += "|" + std::to_string((int)desc.color[i].format) + std::to_string(desc.color[i].premultipliedOver) +
                   std::to_string(desc.color[i].writeEnabled);
        key += "|" + std::to_string(desc.hasDepth ? (int)desc.depthFormat : -1);
        auto found = states_.find(key);
        if (found != states_.end()) return found->second;
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [shared_.device newRenderPipelineStateWithDescriptor:d error:&error];
        if (state) states_[key] = state;
        else NSLog(@"BorosKit MetalDevice: pipeline %s / %s failed: %@", desc.vertex.name, desc.fragment.name, error);
        return state;
    }

    MetalShared shared_;
    std::string name_;
    Limits limits_;
    std::vector<id<MTLLibrary>> libraries_;
    std::map<std::string, id<MTLRenderPipelineState>> states_;
};

}  // namespace

// ---- Public entry points -------------------------------------------------------------------------------------------

Status makeMetalDevice(id<MTLDevice> device, std::unique_ptr<Device> *out)
{
    if (!out) return Status::InvalidArgument;
    // 2026-11-26: nil = the system default GPU (BorosKitGPU no longer depends on BorosKitRender's BKMetalDevice; every
    // BorosKit class passes its own, user-chosen device).
    id<MTLDevice> d = device ?: MTLCreateSystemDefaultDevice();
    if (!d) return Status::NotFound;
    out->reset(new MetalDevice(d));
    return Status::Ok;
}

Status makeMetalDevice(id<MTLDevice> device, id<MTLCommandQueue> queue, std::unique_ptr<Device> *out)
{
    if (!out || !device || (queue && queue.device != device)) return Status::InvalidArgument;
    out->reset(new MetalDevice(device, queue));
    return Status::Ok;
}

Status makeMetalDevice(void *mtlDevice, std::unique_ptr<Device> *out)
{
    return makeMetalDevice((__bridge id<MTLDevice>)mtlDevice, out);
}

Status BKGPUMetalAddLibrary(Device &device, id<MTLLibrary> library)
{
    MetalDevice *m = dynamic_cast<MetalDevice *>(&device);
    if (!m || !library) return Status::InvalidArgument;
    m->addLibrary(library);
    return Status::Ok;
}

std::unique_ptr<Texture> BKGPUMetalWrapTexture(Device &device, id<MTLTexture> texture)
{
    if (!dynamic_cast<MetalDevice *>(&device) || !texture) return nullptr;
    TextureDesc d;
    if (!FromMetal(texture.pixelFormat, &d.format)) return nullptr;
    d.type = texture.textureType == MTLTextureType3D ? TextureType::Texture3D : TextureType::Texture2D;
    d.width = (uint32_t)texture.width;
    d.height = (uint32_t)texture.height;
    d.depth = (uint32_t)texture.depth;
    d.usage = 0;
    if (texture.usage & MTLTextureUsageShaderRead) d.usage |= UsageSampled;
    if (texture.usage & MTLTextureUsageShaderWrite) d.usage |= UsageStorage;
    if (texture.usage & MTLTextureUsageRenderTarget) d.usage |= UsageRenderTarget;
    return std::unique_ptr<Texture>(new MetalTexture(texture, d));
}

std::unique_ptr<Buffer> BKGPUMetalWrapBuffer(Device &device, id<MTLBuffer> buffer)
{
    if (!dynamic_cast<MetalDevice *>(&device) || !buffer) return nullptr;
    return std::unique_ptr<Buffer>(new MetalBuffer(buffer));
}

std::unique_ptr<CommandList> BKGPUMetalCommandList(Device &device, id<MTLCommandBuffer> commandBuffer)
{
    MetalDevice *m = dynamic_cast<MetalDevice *>(&device);
    if (!m || !commandBuffer) return nullptr;
    return std::unique_ptr<CommandList>(new MetalCommandList(m->shared(), commandBuffer, true));
}

id<MTLTexture> BKGPUMetalTexture(Texture &texture)
{
    MetalTexture *t = dynamic_cast<MetalTexture *>(&texture);
    return t ? t->texture : nil;
}

id<MTLBuffer> BKGPUMetalBuffer(Buffer &buffer)
{
    MetalBuffer *b = dynamic_cast<MetalBuffer *>(&buffer);
    return b ? b->buffer : nil;
}

id<MTLDevice> BKGPUMetalDevice(Device &device)
{
    MetalDevice *m = dynamic_cast<MetalDevice *>(&device);
    return m ? m->mtlDevice() : nil;
}

}  // namespace gpu
}  // namespace boroskit
