// BorosKitGPUVulkan: BKVulkanDevice - the Vulkan implementation of the BKGPU.h interface.
//
// Original BorosKit code written for this project; contains no third-party code. Written from the Vulkan
// specification (no sample code copied). Written 2026-11-26 by agent "vulkan-engine" (step M6).
//
// PORTING NOTES (read with BKGPU.h):
//   - Vulkan 1.3 core is required (dynamic rendering: no VkRenderPass / VkFramebuffer objects). Every
//     current desktop driver and MoltenVK (1.4 on this Mac) has it.
//   - Instance: VK_KHR_portability_enumeration + its flag when offered (MoltenVK needs it to be listed);
//     device: VK_KHR_portability_subset whenever the GPU offers it (the specification requires enabling it).
//   - Validation (VulkanOptions): VK_LAYER_KHRONOS_validation; synchronisation validation through
//     VK_EXT_layer_settings ("validate_sync"). Warnings and errors go to VulkanOptions::message.
//   - Memory: own sub-allocator. 64 MB blocks per memory type, separate blocks for buffers and images (so
//     bufferImageGranularity never matters), first-fit free list with merging, requests above 16 MB get a
//     block of their own. Host-visible blocks stay mapped. No third-party allocator.
//   - Barriers are automatic (BKGPU.h): each Texture remembers its layout and last access; transfers into
//     buffers are followed by one memory barrier to every later read. One CommandList in flight at a time
//     (submit waits), which is all milestone 1 needs; asynchronous submission comes with presentation.
//   - Clip space: +y up like Metal - the viewport is set with a NEGATIVE height (core since Vulkan 1.1).
//   - Compute (2026-11-26, phase 3/4): pipelines with the workgroup size as specialization constants 0, 1, 2; after
//     every dispatch one memory barrier (compute writes -> every later read, also the host), so the next command
//     and the CPU (after submit) see the results.
//   - Not implemented yet (Status::Unsupported, honestly reported): storage-image layouts for compute writes,
//     Surface (phase 8), timestamps.

#include "BKVulkanAvailable.h"
#if BK_HAVE_VULKAN_HEADERS   // 2026-11-26: else BKVulkanStub.cpp (build without the SDK)
#include "BKGPUVulkan.h"
#include "BKVulkanLoader.h"
#include "BKVulkanShaderTable.h"
#include "BKGPUChoiceCore.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace boroskit {
namespace gpu {

namespace {

using vk::Functions;

// ---- Small helpers ------------------------------------------------------------------------------------------

VkFormat ToVk(Format f)
{
    switch (f) {
        case Format::R8Unorm: return VK_FORMAT_R8_UNORM;
        case Format::R16Unorm: return VK_FORMAT_R16_UNORM;
        case Format::R32Float: return VK_FORMAT_R32_SFLOAT;
        case Format::R32Uint: return VK_FORMAT_R32_UINT;
        case Format::RGBA8Unorm: return VK_FORMAT_R8G8B8A8_UNORM;
        case Format::BGRA8Unorm: return VK_FORMAT_B8G8R8A8_UNORM;
        case Format::RGBA16Float: return VK_FORMAT_R16G16B16A16_SFLOAT;
        case Format::RGBA32Float: return VK_FORMAT_R32G32B32A32_SFLOAT;
        case Format::Depth32Float: return VK_FORMAT_D32_SFLOAT;
    }
    return VK_FORMAT_UNDEFINED;
}

uint32_t BytesPerTexel(Format f)
{
    switch (f) {
        case Format::R8Unorm: return 1;
        case Format::R16Unorm: return 2;
        case Format::R32Float: case Format::R32Uint: case Format::RGBA8Unorm: case Format::BGRA8Unorm:
        case Format::Depth32Float: return 4;
        case Format::RGBA16Float: return 8;
        case Format::RGBA32Float: return 16;
    }
    return 0;
}

VkDeviceSize AlignUp(VkDeviceSize v, VkDeviceSize a) { return a ? (v + a - 1) / a * a : v; }

void Set(Status *s, Status v) { if (s) *s = v; }

// ---- Memory: BorosKit's own sub-allocator ---------------------------------------------------------------------

struct Allocation {
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize offset = 0, size = 0;
    void *mapped = nullptr;      // host address of `offset` (host-visible memory only)
    int block = -1;
};

class Allocator {
public:
    static constexpr VkDeviceSize kBlockBytes = 64ull << 20;
    static constexpr VkDeviceSize kDedicatedAbove = 16ull << 20;

    void init(const Functions *f, VkDevice device, const VkPhysicalDeviceMemoryProperties &props)
    {
        f_ = f; device_ = device; props_ = props;
    }

    // What: memory for `req` with all `required` property bits, preferring `preferred` ones. isImage keeps
    // images and buffers in different blocks.
    bool allocate(const VkMemoryRequirements &req, VkMemoryPropertyFlags required, VkMemoryPropertyFlags preferred,
                  bool isImage, Allocation *out)
    {
        int type = -1;
        for (int pass = 0; pass < 2 && type < 0; pass++)
            for (uint32_t i = 0; i < props_.memoryTypeCount; i++) {
                VkMemoryPropertyFlags have = props_.memoryTypes[i].propertyFlags;
                if (!(req.memoryTypeBits & (1u << i)) || (have & required) != required) continue;
                if (pass == 0 && (have & preferred) != preferred) continue;
                type = (int)i;
                break;
            }
        if (type < 0) return false;
        bool hostVisible = (props_.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
        std::lock_guard<std::mutex> lock(mutex_);
        if (req.size <= kDedicatedAbove) {
            for (size_t b = 0; b < blocks_.size(); b++)
                if (blocks_[b].memory && !blocks_[b].dedicated && blocks_[b].type == (uint32_t)type &&
                    blocks_[b].isImage == isImage && take(blocks_[b], (int)b, req, out)) return true;
        }
        Block block;
        block.type = (uint32_t)type;
        block.isImage = isImage;
        block.dedicated = req.size > kDedicatedAbove;
        block.size = block.dedicated ? req.size : kBlockBytes;
        VkMemoryAllocateInfo info = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        info.allocationSize = block.size;
        info.memoryTypeIndex = (uint32_t)type;
        if (f_->vkAllocateMemory(device_, &info, nullptr, &block.memory) != VK_SUCCESS) return false;
        if (hostVisible && f_->vkMapMemory(device_, block.memory, 0, VK_WHOLE_SIZE, 0, &block.mapped) != VK_SUCCESS) {
            f_->vkFreeMemory(device_, block.memory, nullptr);
            return false;
        }
        block.free.push_back({ 0, block.size });
        blocks_.push_back(block);
        return take(blocks_.back(), (int)blocks_.size() - 1, req, out);
    }

    void release(const Allocation &a)
    {
        if (a.block < 0) return;
        std::lock_guard<std::mutex> lock(mutex_);
        Block &b = blocks_[(size_t)a.block];
        b.free.push_back({ a.offset, a.size });
        std::sort(b.free.begin(), b.free.end(), [](const Range &x, const Range &y) { return x.offset < y.offset; });
        std::vector<Range> merged;   // join touching free ranges
        for (const Range &r : b.free) {
            if (!merged.empty() && merged.back().offset + merged.back().size == r.offset) merged.back().size += r.size;
            else merged.push_back(r);
        }
        b.free.swap(merged);
        if (b.free.size() == 1 && b.free[0].size == b.size) {   // empty block: give it back
            f_->vkFreeMemory(device_, b.memory, nullptr);
            b.memory = VK_NULL_HANDLE;
            b.mapped = nullptr;
            b.free.clear();
        }
    }

    void destroyAll()
    {
        for (Block &b : blocks_) if (b.memory) f_->vkFreeMemory(device_, b.memory, nullptr);
        blocks_.clear();
    }

private:
    struct Range { VkDeviceSize offset, size; };
    struct Block {
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkDeviceSize size = 0;
        uint32_t type = 0;
        bool isImage = false, dedicated = false;
        void *mapped = nullptr;
        std::vector<Range> free;
    };

    // First fit with alignment: split the free range around the piece taken.
    bool take(Block &b, int index, const VkMemoryRequirements &req, Allocation *out)
    {
        for (size_t i = 0; i < b.free.size(); i++) {
            Range r = b.free[i];
            VkDeviceSize start = AlignUp(r.offset, req.alignment);
            if (start + req.size > r.offset + r.size) continue;
            b.free.erase(b.free.begin() + (long)i);
            if (start > r.offset) b.free.push_back({ r.offset, start - r.offset });
            VkDeviceSize end = start + req.size;
            if (end < r.offset + r.size) b.free.push_back({ end, r.offset + r.size - end });
            out->memory = b.memory;
            out->offset = start;
            out->size = req.size;
            out->mapped = b.mapped ? static_cast<uint8_t *>(b.mapped) + start : nullptr;
            out->block = index;
            // The piece handed out is [start, end); the alignment gap before it went back to the free list.
            return true;
        }
        return false;
    }

    const Functions *f_ = nullptr;
    VkDevice device_ = VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties props_ = {};
    std::vector<Block> blocks_;
    std::mutex mutex_;
};

// ---- What every resource needs to reach -------------------------------------------------------------------------

struct Context {
    Functions f;
    VulkanOptions options;
    VkInstance instance = VK_NULL_HANDLE;
    VkDebugUtilsMessengerEXT messenger = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;
    VkPhysicalDeviceProperties properties = {};
    std::string name, driverName;
    Allocator allocator;
};

VKAPI_ATTR VkBool32 VKAPI_CALL DebugMessage(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
                                            VkDebugUtilsMessageTypeFlagsEXT, const VkDebugUtilsMessengerCallbackDataEXT *data,
                                            void *user)
{
    const VulkanOptions *o = static_cast<const VulkanOptions *>(user);
    bool isError = (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0;
    const char *text = data && data->pMessage ? data->pMessage : "(no text)";
    if (o && o->message) o->message(o->messageContext, isError, text);
    else std::fprintf(stderr, "Vulkan %s: %s\n", isError ? "ERROR" : "warning", text);
    return VK_FALSE;
}

// ---- Resources ----------------------------------------------------------------------------------------------------

class VulkanBuffer final : public Buffer {
public:
    VulkanBuffer(Context *c) : c_(c) {}
    ~VulkanBuffer() override
    {
        if (buffer) c_->f.vkDestroyBuffer(c_->device, buffer, nullptr);
        c_->allocator.release(memory);
    }
    uint64_t size() const override { return bytes; }
    void *map() override { return memory.mapped; }    // host-visible memory is coherent and stays mapped
    void unmap() override {}

    VkBuffer buffer = VK_NULL_HANDLE;
    Allocation memory;
    uint64_t bytes = 0;
private:
    Context *c_;
};

class VulkanTexture final : public Texture {
public:
    VulkanTexture(Context *c) : c_(c) {}
    ~VulkanTexture() override
    {
        if (view) c_->f.vkDestroyImageView(c_->device, view, nullptr);
        if (image) c_->f.vkDestroyImage(c_->device, image, nullptr);
        c_->allocator.release(memory);
    }
    const TextureDesc &desc() const override { return desc_; }

    TextureDesc desc_;
    VkImage image = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    Allocation memory;
    VkImageAspectFlags aspect = VK_IMAGE_ASPECT_COLOR_BIT;
    // Automatic barriers: where the image is now.
    VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    VkAccessFlags access = 0;
private:
    Context *c_;
};

class VulkanSampler final : public Sampler {
public:
    VulkanSampler(Context *c) : c_(c) {}
    ~VulkanSampler() override { if (sampler) c_->f.vkDestroySampler(c_->device, sampler, nullptr); }
    VkSampler sampler = VK_NULL_HANDLE;
private:
    Context *c_;
};

VkDescriptorType DescriptorType(SlotKind k)
{
    switch (k) {
        case SlotKind::UniformBlock: return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        case SlotKind::StorageBuffer: return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        case SlotKind::SampledTexture: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        case SlotKind::StorageImage: return VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        case SlotKind::Sampler: return VK_DESCRIPTOR_TYPE_SAMPLER;
    }
    return VK_DESCRIPTOR_TYPE_MAX_ENUM;
}

uint32_t BindingNumber(SlotKind k, uint32_t slot) { return kSlotBase[(int)k] + slot; }

class VulkanComputePipeline final : public ComputePipeline {
public:
    VulkanComputePipeline(Context *c) : c_(c) {}
    ~VulkanComputePipeline() override
    {
        if (pipeline) c_->f.vkDestroyPipeline(c_->device, pipeline, nullptr);
        if (layout) c_->f.vkDestroyPipelineLayout(c_->device, layout, nullptr);
        if (setLayout) c_->f.vkDestroyDescriptorSetLayout(c_->device, setLayout, nullptr);
    }
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
private:
    Context *c_;
};

class VulkanRenderPipeline final : public RenderPipeline {
public:
    VulkanRenderPipeline(Context *c) : c_(c) {}
    ~VulkanRenderPipeline() override
    {
        if (pipeline) c_->f.vkDestroyPipeline(c_->device, pipeline, nullptr);
        if (layout) c_->f.vkDestroyPipelineLayout(c_->device, layout, nullptr);
        if (setLayout) c_->f.vkDestroyDescriptorSetLayout(c_->device, setLayout, nullptr);
    }
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
private:
    Context *c_;
};

// ---- Recording ------------------------------------------------------------------------------------------------------

class VulkanCommandList final : public CommandList {
public:
    explicit VulkanCommandList(Context *c) : c_(c) {}
    ~VulkanCommandList() override
    {
        if (pool_) c_->f.vkDestroyCommandPool(c_->device, pool_, nullptr);
        if (descriptors_) c_->f.vkDestroyDescriptorPool(c_->device, descriptors_, nullptr);
    }

    Status start()
    {
        VkCommandPoolCreateInfo pi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
        pi.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        pi.queueFamilyIndex = c_->queueFamily;
        if (c_->f.vkCreateCommandPool(c_->device, &pi, nullptr, &pool_) != VK_SUCCESS) return Status::OutOfMemory;
        VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ai.commandPool = pool_;
        ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        ai.commandBufferCount = 1;
        if (c_->f.vkAllocateCommandBuffers(c_->device, &ai, &cb_) != VK_SUCCESS) return Status::OutOfMemory;
        // One descriptor pool per command list (reset with it): plenty for a frame of BorosKit work.
        VkDescriptorPoolSize sizes[5] = {
            { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1024 }, { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1024 },
            { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1024 }, { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 256 },
            { VK_DESCRIPTOR_TYPE_SAMPLER, 256 } };
        VkDescriptorPoolCreateInfo dp = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
        dp.maxSets = 512;
        dp.poolSizeCount = 5;
        dp.pPoolSizes = sizes;
        if (c_->f.vkCreateDescriptorPool(c_->device, &dp, nullptr, &descriptors_) != VK_SUCCESS) return Status::OutOfMemory;
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        return c_->f.vkBeginCommandBuffer(cb_, &bi) == VK_SUCCESS ? Status::Ok : Status::OutOfMemory;
    }

    VkCommandBuffer commandBuffer() const { return cb_; }
    bool inPass() const { return inPass_; }

    // ---- copies ----
    Status upload(Texture &texture, const void *data, uint32_t rowBytes, uint32_t sliceBytes, uint32_t firstSlice,
                  uint32_t sliceCount) override
    {
        if (inPass_ || !data) return Status::InvalidArgument;
        VulkanTexture &t = static_cast<VulkanTexture &>(texture);
        const TextureDesc &d = t.desc();
        uint32_t texel = BytesPerTexel(d.format);
        uint32_t tight = d.width * texel;
        if (rowBytes < tight || sliceBytes < rowBytes * d.height || firstSlice + sliceCount > d.depth) return Status::InvalidArgument;
        VulkanBuffer *staging = stagingBuffer((uint64_t)tight * d.height * sliceCount);
        if (!staging) return Status::OutOfMemory;
        uint8_t *dst = static_cast<uint8_t *>(staging->map());
        for (uint32_t z = 0; z < sliceCount; z++)
            for (uint32_t y = 0; y < d.height; y++)
                std::memcpy(dst + ((size_t)z * d.height + y) * tight,
                            static_cast<const uint8_t *>(data) + (size_t)z * sliceBytes + (size_t)y * rowBytes, tight);
        transition(t, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT);
        VkBufferImageCopy region = {};
        region.imageSubresource.aspectMask = t.aspect;
        region.imageSubresource.layerCount = 1;
        region.imageOffset.z = (int32_t)firstSlice;
        region.imageExtent = { d.width, d.height, sliceCount };
        c_->f.vkCmdCopyBufferToImage(cb_, staging->buffer, t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        // Sampled textures go straight to the layout shaders read (no layout change is allowed inside a pass).
        if (d.usage & UsageSampled)
            transition(t, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                       VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                       VK_ACCESS_SHADER_READ_BIT);
        return Status::Ok;
    }

    Status upload(Buffer &buffer, uint64_t offset, const void *data, uint64_t bytes) override
    {
        VulkanBuffer &b = static_cast<VulkanBuffer &>(buffer);
        if (inPass_ || !data || offset + bytes > b.bytes) return Status::InvalidArgument;
        VulkanBuffer *staging = stagingBuffer(bytes);
        if (!staging) return Status::OutOfMemory;
        std::memcpy(staging->map(), data, (size_t)bytes);
        VkBufferCopy region = { 0, offset, bytes };
        c_->f.vkCmdCopyBuffer(cb_, staging->buffer, b.buffer, 1, &region);
        transferToAllReads();
        return Status::Ok;
    }

    Status readback(Texture &texture, Buffer &destination) override
    {
        VulkanTexture &t = static_cast<VulkanTexture &>(texture);
        VulkanBuffer &b = static_cast<VulkanBuffer &>(destination);
        const TextureDesc &d = t.desc();
        if (inPass_ || (uint64_t)d.width * d.height * d.depth * BytesPerTexel(d.format) > b.bytes) return Status::InvalidArgument;
        transition(t, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT);
        VkBufferImageCopy region = {};
        region.imageSubresource.aspectMask = t.aspect;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = { d.width, d.height, d.depth };
        c_->f.vkCmdCopyImageToBuffer(cb_, t.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, b.buffer, 1, &region);
        transferToHost();
        return Status::Ok;
    }

    Status copy(Buffer &source, uint64_t sourceOffset, Buffer &destination, uint64_t destinationOffset, uint64_t bytes) override
    {
        VulkanBuffer &s = static_cast<VulkanBuffer &>(source), &d = static_cast<VulkanBuffer &>(destination);
        if (inPass_ || sourceOffset + bytes > s.bytes || destinationOffset + bytes > d.bytes) return Status::InvalidArgument;
        VkBufferCopy region = { sourceOffset, destinationOffset, bytes };
        c_->f.vkCmdCopyBuffer(cb_, s.buffer, d.buffer, 1, &region);
        transferToAllReads();
        transferToHost();
        return Status::Ok;
    }

    Status dispatch(ComputePipeline &pipeline, const Binding *bindings, uint32_t bindingCount,
                    uint32_t groupsX, uint32_t groupsY, uint32_t groupsZ) override
    {
        if (inPass_) return Status::InvalidArgument;
        VulkanComputePipeline &p = static_cast<VulkanComputePipeline &>(pipeline);
        VkDescriptorSet set = VK_NULL_HANDLE;
        Status s = writeDescriptors(p.setLayout, bindings, bindingCount, &set);
        if (s != Status::Ok) return s;
        c_->f.vkCmdBindPipeline(cb_, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipeline);
        if (set) c_->f.vkCmdBindDescriptorSets(cb_, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, &set, 0, nullptr);
        c_->f.vkCmdDispatch(cb_, groupsX, groupsY, groupsZ);
        // The automatic barrier: what this dispatch wrote is visible to every later command and to the host.
        memoryBarrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
                      VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
                      VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_HOST_READ_BIT);
        return Status::Ok;
    }

    // ---- drawing ----
    Status beginPass(const PassTargets &targets) override
    {
        if (inPass_ || targets.colorCount > 2 || (targets.colorCount == 0 && !targets.depth)) return Status::InvalidArgument;
        VkRenderingAttachmentInfo colors[2] = {};
        uint32_t width = 0, height = 0;
        for (uint32_t i = 0; i < targets.colorCount; i++) {
            VulkanTexture *t = static_cast<VulkanTexture *>(targets.color[i]);
            if (!t) return Status::InvalidArgument;
            if (targets.clearColor[i]) discardContents(*t);
            transition(*t, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                       VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);
            colors[i].sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
            colors[i].imageView = t->view;
            colors[i].imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            colors[i].loadOp = targets.clearColor[i] ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
            colors[i].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
            for (int k = 0; k < 4; k++) colors[i].clearValue.color.float32[k] = targets.clearValue[i][k];
            width = t->desc().width;
            height = t->desc().height;
        }
        VkRenderingAttachmentInfo depth = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO };
        if (targets.depth) {
            VulkanTexture *t = static_cast<VulkanTexture *>(targets.depth);
            discardContents(*t);
            transition(*t, VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
                       VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                       VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT);
            depth.imageView = t->view;
            depth.imageLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
            depth.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
            depth.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;   // like Metal's MTLStoreActionDontCare
            depth.clearValue.depthStencil.depth = targets.clearDepth;
            if (!width) { width = t->desc().width; height = t->desc().height; }
        }
        VkRenderingInfo info = { VK_STRUCTURE_TYPE_RENDERING_INFO };
        info.renderArea.extent = { width, height };
        info.layerCount = 1;
        info.colorAttachmentCount = targets.colorCount;
        info.pColorAttachments = colors;
        info.pDepthAttachment = targets.depth ? &depth : nullptr;
        c_->f.vkCmdBeginRendering(cb_, &info);
        inPass_ = true;
        // Viewport: Metal's convention (+y up in clip space, depth 0..1) via a negative height.
        int32_t vx = targets.viewport[0], vy = targets.viewport[1];
        int32_t vw = targets.viewport[2], vh = targets.viewport[3];
        if (vw <= 0 || vh <= 0) { vx = 0; vy = 0; vw = (int32_t)width; vh = (int32_t)height; }
        VkViewport viewport = { (float)vx, (float)(vy + vh), (float)vw, -(float)vh, 0.0f, 1.0f };
        c_->f.vkCmdSetViewport(cb_, 0, 1, &viewport);
        setScissor(vx, vy, vw, vh);
        return Status::Ok;
    }

    void setScissor(int32_t x, int32_t y, int32_t width, int32_t height) override
    {
        VkRect2D r = { { std::max(x, 0), std::max(y, 0) }, { (uint32_t)std::max(width, 0), (uint32_t)std::max(height, 0) } };
        c_->f.vkCmdSetScissor(cb_, 0, 1, &r);
    }

    Status draw(RenderPipeline &pipeline, const Binding *bindings, uint32_t bindingCount, uint32_t vertexCount,
                uint32_t firstVertex, Buffer *indices, uint32_t indexCount) override
    {
        if (!inPass_) return Status::InvalidArgument;
        VulkanRenderPipeline &p = static_cast<VulkanRenderPipeline &>(pipeline);
        VkDescriptorSet set = VK_NULL_HANDLE;
        Status s = writeDescriptors(p.setLayout, bindings, bindingCount, &set);
        if (s != Status::Ok) return s;
        c_->f.vkCmdBindPipeline(cb_, VK_PIPELINE_BIND_POINT_GRAPHICS, p.pipeline);
        if (set) c_->f.vkCmdBindDescriptorSets(cb_, VK_PIPELINE_BIND_POINT_GRAPHICS, p.layout, 0, 1, &set, 0, nullptr);
        if (indices) {
            c_->f.vkCmdBindIndexBuffer(cb_, static_cast<VulkanBuffer *>(indices)->buffer, 0, VK_INDEX_TYPE_UINT32);
            c_->f.vkCmdDrawIndexed(cb_, indexCount, 1, 0, (int32_t)firstVertex, 0);
        } else {
            c_->f.vkCmdDraw(cb_, vertexCount, 1, firstVertex, 0);
        }
        return Status::Ok;
    }

    void endPass() override
    {
        if (!inPass_) return;
        c_->f.vkCmdEndRendering(cb_);
        inPass_ = false;
    }

    void timestamp(uint32_t) override {}   // Limits::timestamps is false for now

private:
    // A host-visible buffer that lives as long as this command list (staging / small constants).
    VulkanBuffer *stagingBuffer(uint64_t bytes, uint32_t usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
    {
        VulkanBuffer *b = new VulkanBuffer(c_);
        keep_.emplace_back(b);
        VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        bi.size = std::max<uint64_t>(bytes, 4);
        bi.usage = usage;
        bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (c_->f.vkCreateBuffer(c_->device, &bi, nullptr, &b->buffer) != VK_SUCCESS) return nullptr;
        VkMemoryRequirements req;
        c_->f.vkGetBufferMemoryRequirements(c_->device, b->buffer, &req);
        if (!c_->allocator.allocate(req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, 0, false, &b->memory))
            return nullptr;
        if (c_->f.vkBindBufferMemory(c_->device, b->buffer, b->memory.memory, b->memory.offset) != VK_SUCCESS) return nullptr;
        b->bytes = bi.size;
        return b;
    }

    // Image layout change + the memory dependency on its last use (the automatic barrier).
    void transition(VulkanTexture &t, VkImageLayout layout, VkPipelineStageFlags stage, VkAccessFlags access)
    {
        const VkAccessFlags writes = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                                     VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
        // Same layout, only reads before and after: nothing to wait for.
        if (t.layout == layout && !(t.access & writes) && !(access & writes)) { t.stage |= stage; t.access |= access; return; }
        VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        b.srcAccessMask = t.access;
        b.dstAccessMask = access;
        b.oldLayout = t.layout;
        b.newLayout = layout;
        b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        b.image = t.image;
        b.subresourceRange = { t.aspect, 0, 1, 0, 1 };
        c_->f.vkCmdPipelineBarrier(cb_, t.stage, stage, 0, 0, nullptr, 0, nullptr, 1, &b);
        t.layout = layout;
        t.stage = stage;
        t.access = access;
    }

    // A target about to be cleared: its old contents do not matter (layout UNDEFINED is allowed as "old").
    void discardContents(VulkanTexture &t)
    {
        if (t.layout == VK_IMAGE_LAYOUT_UNDEFINED) return;
        t.layout = VK_IMAGE_LAYOUT_UNDEFINED;   // the barrier below still waits for the previous use
    }

    void memoryBarrier(VkPipelineStageFlags src, VkAccessFlags srcAccess, VkPipelineStageFlags dst, VkAccessFlags dstAccess)
    {
        VkMemoryBarrier m = { VK_STRUCTURE_TYPE_MEMORY_BARRIER };
        m.srcAccessMask = srcAccess;
        m.dstAccessMask = dstAccess;
        c_->f.vkCmdPipelineBarrier(cb_, src, dst, 0, 1, &m, 0, nullptr, 0, nullptr);
    }
    void transferToAllReads()
    {
        memoryBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                      VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
    }
    void transferToHost()
    {
        memoryBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    }

    // One descriptor set for one draw; small constant blocks are copied into a uniform buffer of this list.
    Status writeDescriptors(VkDescriptorSetLayout layout, const Binding *bindings, uint32_t count, VkDescriptorSet *out)
    {
        *out = VK_NULL_HANDLE;
        if (count == 0) return Status::Ok;
        VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
        ai.descriptorPool = descriptors_;
        ai.descriptorSetCount = 1;
        ai.pSetLayouts = &layout;
        if (c_->f.vkAllocateDescriptorSets(c_->device, &ai, out) != VK_SUCCESS) return Status::OutOfMemory;
        std::vector<VkWriteDescriptorSet> writes(count);
        std::vector<VkDescriptorBufferInfo> buffers(count);
        std::vector<VkDescriptorImageInfo> images(count);
        for (uint32_t i = 0; i < count; i++) {
            const Binding &b = bindings[i];
            VkWriteDescriptorSet &w = writes[i];
            w = VkWriteDescriptorSet{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
            w.dstSet = *out;
            w.dstBinding = BindingNumber(b.kind, b.slot);
            w.descriptorCount = 1;
            w.descriptorType = DescriptorType(b.kind);
            if (b.kind == SlotKind::UniformBlock || b.kind == SlotKind::StorageBuffer) {
                if (b.bytes) {
                    if (b.byteCount == 0 || b.byteCount > kMaxInlineBytes) return Status::InvalidArgument;
                    VulkanBuffer *u = stagingBuffer(b.byteCount, b.kind == SlotKind::UniformBlock ? VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT
                                                                                                 : VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
                    if (!u) return Status::OutOfMemory;
                    std::memcpy(u->map(), b.bytes, b.byteCount);
                    buffers[i] = { u->buffer, 0, b.byteCount };
                } else if (b.buffer) {
                    buffers[i] = { static_cast<VulkanBuffer *>(b.buffer)->buffer, b.offset, VK_WHOLE_SIZE };
                } else {
                    return Status::InvalidArgument;
                }
                w.pBufferInfo = &buffers[i];
            } else if (b.kind == SlotKind::Sampler) {
                if (!b.sampler) return Status::InvalidArgument;
                images[i] = { static_cast<VulkanSampler *>(b.sampler)->sampler, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED };
                w.pImageInfo = &images[i];
            } else {
                VulkanTexture *t = static_cast<VulkanTexture *>(b.texture);
                if (!t) return Status::InvalidArgument;
                images[i] = { VK_NULL_HANDLE, t->view, b.kind == SlotKind::StorageImage ? VK_IMAGE_LAYOUT_GENERAL
                                                                                        : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
                w.pImageInfo = &images[i];
            }
        }
        c_->f.vkUpdateDescriptorSets(c_->device, count, writes.data(), 0, nullptr);
        return Status::Ok;
    }

    Context *c_;
    VkCommandPool pool_ = VK_NULL_HANDLE;
    VkCommandBuffer cb_ = VK_NULL_HANDLE;
    VkDescriptorPool descriptors_ = VK_NULL_HANDLE;
    std::vector<std::unique_ptr<VulkanBuffer>> keep_;   // staging and constant buffers of this list
    bool inPass_ = false;
};

// ---- The device -----------------------------------------------------------------------------------------------------

class VulkanDevice final : public Device {
public:
    ~VulkanDevice() override
    {
        Functions &f = c_.f;
        if (c_.device) {
            f.vkDeviceWaitIdle(c_.device);
            c_.allocator.destroyAll();
            f.vkDestroyDevice(c_.device, nullptr);
        }
        if (c_.messenger && f.vkDestroyDebugUtilsMessengerEXT) f.vkDestroyDebugUtilsMessengerEXT(c_.instance, c_.messenger, nullptr);
        if (c_.instance) f.vkDestroyInstance(c_.instance, nullptr);
    }

    Status create(const VulkanOptions &options);

    const Limits &limits() const override { return limits_; }
    const char *name() const override { return c_.name.c_str(); }
    const char *driverName() const { return c_.driverName.c_str(); }

    std::unique_ptr<Buffer> makeBuffer(uint64_t bytes, Memory memory, uint32_t usage, Status *status) override
    {
        if (bytes == 0) { Set(status, Status::InvalidArgument); return nullptr; }
        std::unique_ptr<VulkanBuffer> b(new VulkanBuffer(&c_));
        VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        bi.size = bytes;
        bi.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        if (usage & UsageStorage) bi.usage |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        if (usage & UsageSampled) bi.usage |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        if (usage & UsageIndex) bi.usage |= VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
        bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (c_.f.vkCreateBuffer(c_.device, &bi, nullptr, &b->buffer) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
        VkMemoryRequirements req;
        c_.f.vkGetBufferMemoryRequirements(c_.device, b->buffer, &req);
        VkMemoryPropertyFlags required = 0, preferred = 0;
        if (memory == Memory::DeviceOnly) preferred = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        else required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if (memory == Memory::Readback) preferred = VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
        if (!c_.allocator.allocate(req, required, preferred, false, &b->memory) ||
            c_.f.vkBindBufferMemory(c_.device, b->buffer, b->memory.memory, b->memory.offset) != VK_SUCCESS) {
            Set(status, Status::OutOfMemory);
            return nullptr;
        }
        b->bytes = bytes;
        Set(status, Status::Ok);
        return std::unique_ptr<Buffer>(b.release());
    }

    std::unique_ptr<Texture> makeTexture(const TextureDesc &desc, Status *status) override
    {
        bool is3D = desc.type == TextureType::Texture3D;
        uint32_t maxSide = is3D ? limits_.maxImage3D : limits_.maxImage2D;
        if (desc.width == 0 || desc.height == 0 || desc.depth == 0 || (!is3D && desc.depth != 1) ||
            desc.width > maxSide || desc.height > maxSide || desc.depth > (is3D ? maxSide : 1u)) {
            Set(status, Status::InvalidArgument);
            return nullptr;
        }
        bool depth = desc.format == Format::Depth32Float;
        if (depth && !limits_.depth32Float) { Set(status, Status::Unsupported); return nullptr; }
        std::unique_ptr<VulkanTexture> t(new VulkanTexture(&c_));
        t->desc_ = desc;
        t->aspect = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
        VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
        ii.imageType = is3D ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D;
        ii.format = ToVk(desc.format);
        ii.extent = { desc.width, desc.height, desc.depth };
        ii.mipLevels = 1;
        ii.arrayLayers = 1;
        ii.samples = VK_SAMPLE_COUNT_1_BIT;
        ii.tiling = VK_IMAGE_TILING_OPTIMAL;
        ii.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;   // upload / readback always possible
        if (desc.usage & UsageSampled) ii.usage |= VK_IMAGE_USAGE_SAMPLED_BIT;
        if (desc.usage & UsageStorage) ii.usage |= VK_IMAGE_USAGE_STORAGE_BIT;
        if (desc.usage & UsageRenderTarget) ii.usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        if ((desc.usage & UsageDepthTarget) || depth) ii.usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        if (depth) ii.usage &= ~(VkImageUsageFlags)VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (c_.f.vkCreateImage(c_.device, &ii, nullptr, &t->image) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
        VkMemoryRequirements req;
        c_.f.vkGetImageMemoryRequirements(c_.device, t->image, &req);
        if (!c_.allocator.allocate(req, 0, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, true, &t->memory) ||
            c_.f.vkBindImageMemory(c_.device, t->image, t->memory.memory, t->memory.offset) != VK_SUCCESS) {
            Set(status, Status::OutOfMemory);
            return nullptr;
        }
        VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        vi.image = t->image;
        vi.viewType = is3D ? VK_IMAGE_VIEW_TYPE_3D : VK_IMAGE_VIEW_TYPE_2D;
        vi.format = ii.format;
        vi.subresourceRange = { t->aspect, 0, 1, 0, 1 };
        if (c_.f.vkCreateImageView(c_.device, &vi, nullptr, &t->view) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
        Set(status, Status::Ok);
        return std::unique_ptr<Texture>(t.release());
    }

    std::unique_ptr<Sampler> makeSampler(const SamplerDesc &desc, Status *status) override
    {
        std::unique_ptr<VulkanSampler> s(new VulkanSampler(&c_));
        VkSamplerCreateInfo si = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
        si.magFilter = si.minFilter = desc.linear ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;
        si.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        si.addressModeU = si.addressModeV = si.addressModeW =
            desc.repeat ? VK_SAMPLER_ADDRESS_MODE_REPEAT : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        si.unnormalizedCoordinates = desc.normalizedCoordinates ? VK_FALSE : VK_TRUE;
        si.maxLod = 0.0f;   // never mipmapped
        if (c_.f.vkCreateSampler(c_.device, &si, nullptr, &s->sampler) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
        Set(status, Status::Ok);
        return std::unique_ptr<Sampler>(s.release());
    }

    std::unique_ptr<ComputePipeline> makeCompute(const ComputeDesc &desc, Status *status) override;

    std::unique_ptr<RenderPipeline> makeRender(const RenderDesc &desc, Status *status) override;

    std::unique_ptr<CommandList> begin(Status *status) override
    {
        std::unique_ptr<VulkanCommandList> list(new VulkanCommandList(&c_));
        Status s = list->start();
        Set(status, s);
        return s == Status::Ok ? std::unique_ptr<CommandList>(list.release()) : nullptr;
    }

    Status submit(CommandList &work, bool, void (*done)(void *, Status), void *context) override
    {
        VulkanCommandList &list = static_cast<VulkanCommandList &>(work);
        if (list.inPass()) list.endPass();
        VkCommandBuffer cb = list.commandBuffer();
        if (c_.f.vkEndCommandBuffer(cb) != VK_SUCCESS) return Status::InvalidArgument;
        VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        VkFence fence = VK_NULL_HANDLE;
        if (c_.f.vkCreateFence(c_.device, &fi, nullptr, &fence) != VK_SUCCESS) return Status::OutOfMemory;
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cb;
        VkResult r = c_.f.vkQueueSubmit(c_.queue, 1, &si, fence);
        if (r == VK_SUCCESS) r = c_.f.vkWaitForFences(c_.device, 1, &fence, VK_TRUE, UINT64_MAX);
        c_.f.vkDestroyFence(c_.device, fence, nullptr);
        Status s = r == VK_SUCCESS ? Status::Ok : (r == VK_ERROR_DEVICE_LOST ? Status::DeviceLost : Status::OutOfMemory);
        // Always waits for now (see PORTING NOTES); `done` is still called so callers can be written for later.
        if (done) done(context, s);
        return s;
    }

private:
    Context c_;
    Limits limits_;
};

VkShaderModule MakeModule(Context &c, const char *name)
{
    const vk::EmbeddedShader *shader = vk::FindShader(name);
    if (!shader) return VK_NULL_HANDLE;
    VkShaderModuleCreateInfo mi = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    mi.codeSize = shader->wordCount * 4;
    mi.pCode = shader->words;
    VkShaderModule module = VK_NULL_HANDLE;
    return c.f.vkCreateShaderModule(c.device, &mi, nullptr, &module) == VK_SUCCESS ? module : VK_NULL_HANDLE;
}

std::unique_ptr<RenderPipeline> VulkanDevice::makeRender(const RenderDesc &desc, Status *status)
{
    if (desc.colorCount > 2 || desc.slotCount > 48 || (desc.wireframe && !limits_.wireframe)) {
        Set(status, desc.wireframe ? Status::Unsupported : Status::InvalidArgument);
        return nullptr;
    }
    std::unique_ptr<VulkanRenderPipeline> p(new VulkanRenderPipeline(&c_));
    // Descriptor set 0 from the slot list (binding = kind base + slot, see BKGPU.h).
    std::vector<VkDescriptorSetLayoutBinding> bindings;
    for (uint32_t i = 0; i < desc.slotCount; i++) {
        const SlotLayout &s = desc.slots[i];
        VkDescriptorSetLayoutBinding b = {};
        b.binding = BindingNumber(s.kind, s.slot);
        b.descriptorType = DescriptorType(s.kind);
        b.descriptorCount = 1;
        b.stageFlags = (s.vertexStage ? VK_SHADER_STAGE_VERTEX_BIT : 0) | (s.fragmentStage ? VK_SHADER_STAGE_FRAGMENT_BIT : 0);
        bindings.push_back(b);
    }
    VkDescriptorSetLayoutCreateInfo dl = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dl.bindingCount = (uint32_t)bindings.size();
    dl.pBindings = bindings.data();
    if (c_.f.vkCreateDescriptorSetLayout(c_.device, &dl, nullptr, &p->setLayout) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
    VkPipelineLayoutCreateInfo pl = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pl.setLayoutCount = 1;
    pl.pSetLayouts = &p->setLayout;
    if (c_.f.vkCreatePipelineLayout(c_.device, &pl, nullptr, &p->layout) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }

    VkShaderModule vs = MakeModule(c_, desc.vertex.name), fs = MakeModule(c_, desc.fragment.name);
    if (!vs || !fs) {
        if (vs) c_.f.vkDestroyShaderModule(c_.device, vs, nullptr);
        if (fs) c_.f.vkDestroyShaderModule(c_.device, fs, nullptr);
        Set(status, Status::NotFound);
        return nullptr;
    }
    VkPipelineShaderStageCreateInfo stages[2] = { { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO },
                                                  { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO } };
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vs;
    stages[0].pName = "main";
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fs;
    stages[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vertexInput = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };   // none: vertices come from storage buffers
    VkPipelineInputAssemblyStateCreateInfo assembly = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    raster.polygonMode = desc.wireframe ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL;
    raster.cullMode = desc.cull == CullMode::Back ? VK_CULL_MODE_BACK_BIT : (desc.cull == CullMode::Front ? VK_CULL_MODE_FRONT_BIT : VK_CULL_MODE_NONE);
    raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;   // with the flipped viewport = Metal's CCW rule (to be checked by a culling golden case)
    raster.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo multisample = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = { VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    depth.depthTestEnable = desc.hasDepth && desc.depthCompare != DepthCompare::Always;
    depth.depthWriteEnable = desc.hasDepth && desc.depthWrite;
    depth.depthCompareOp = desc.depthCompare == DepthCompare::Less ? VK_COMPARE_OP_LESS
                         : (desc.depthCompare == DepthCompare::LessOrEqual ? VK_COMPARE_OP_LESS_OR_EQUAL : VK_COMPARE_OP_ALWAYS);
    VkPipelineColorBlendAttachmentState blends[2] = {};
    VkFormat colorFormats[2] = {};
    for (uint32_t i = 0; i < desc.colorCount; i++) {
        const ColorTarget &t = desc.color[i];
        colorFormats[i] = ToVk(t.format);
        VkPipelineColorBlendAttachmentState &b = blends[i];
        b.colorWriteMask = t.writeEnabled ? (VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT) : 0;
        if (t.premultipliedOver) {   // result = source + (1 - source alpha) * destination, colour and alpha
            b.blendEnable = VK_TRUE;
            b.srcColorBlendFactor = b.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
            b.dstColorBlendFactor = b.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
            b.colorBlendOp = b.alphaBlendOp = VK_BLEND_OP_ADD;
        } else if (t.straightOverKeepAlpha) {   // 2026-11-26: colour straight-alpha over, destination alpha kept
            b.blendEnable = VK_TRUE;
            b.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
            b.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
            b.srcAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
            b.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
            b.colorBlendOp = b.alphaBlendOp = VK_BLEND_OP_ADD;
        }
    }
    VkPipelineColorBlendStateCreateInfo blend = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    blend.attachmentCount = desc.colorCount;
    blend.pAttachments = blends;
    VkDynamicState dynamics[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dynamic = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    dynamic.dynamicStateCount = 2;
    dynamic.pDynamicStates = dynamics;
    VkPipelineRenderingCreateInfo rendering = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO };
    rendering.colorAttachmentCount = desc.colorCount;
    rendering.pColorAttachmentFormats = colorFormats;
    rendering.depthAttachmentFormat = desc.hasDepth ? ToVk(desc.depthFormat) : VK_FORMAT_UNDEFINED;
    VkGraphicsPipelineCreateInfo gi = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gi.pNext = &rendering;
    gi.stageCount = 2;
    gi.pStages = stages;
    gi.pVertexInputState = &vertexInput;
    gi.pInputAssemblyState = &assembly;
    gi.pViewportState = &viewport;
    gi.pRasterizationState = &raster;
    gi.pMultisampleState = &multisample;
    gi.pDepthStencilState = &depth;
    gi.pColorBlendState = &blend;
    gi.pDynamicState = &dynamic;
    gi.layout = p->layout;
    VkResult r = c_.f.vkCreateGraphicsPipelines(c_.device, VK_NULL_HANDLE, 1, &gi, nullptr, &p->pipeline);
    c_.f.vkDestroyShaderModule(c_.device, vs, nullptr);
    c_.f.vkDestroyShaderModule(c_.device, fs, nullptr);
    if (r != VK_SUCCESS) { Set(status, Status::CompileFailed); return nullptr; }
    Set(status, Status::Ok);
    return std::unique_ptr<RenderPipeline>(p.release());
}

// What: a compute pipeline; the workgroup size goes in as specialization constants 0, 1, 2 (local_size_*_id).
std::unique_ptr<ComputePipeline> VulkanDevice::makeCompute(const ComputeDesc &desc, Status *status)
{
    const uint32_t *w = desc.workgroup;
    uint64_t threads = (uint64_t)w[0] * w[1] * w[2];
    if (threads == 0 || threads > limits_.maxComputeWorkgroupInvocations || w[0] > limits_.maxComputeWorkgroupSize[0] ||
        w[1] > limits_.maxComputeWorkgroupSize[1] || w[2] > limits_.maxComputeWorkgroupSize[2] || desc.slotCount > 48) {
        Set(status, threads == 0 ? Status::InvalidArgument : Status::Unsupported);
        return nullptr;
    }
    std::unique_ptr<VulkanComputePipeline> p(new VulkanComputePipeline(&c_));
    std::vector<VkDescriptorSetLayoutBinding> bindings;
    for (uint32_t i = 0; i < desc.slotCount; i++) {
        VkDescriptorSetLayoutBinding b = {};
        b.binding = BindingNumber(desc.slots[i].kind, desc.slots[i].slot);
        b.descriptorType = DescriptorType(desc.slots[i].kind);
        b.descriptorCount = 1;
        b.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
        bindings.push_back(b);
    }
    VkDescriptorSetLayoutCreateInfo dl = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    dl.bindingCount = (uint32_t)bindings.size();
    dl.pBindings = bindings.data();
    if (c_.f.vkCreateDescriptorSetLayout(c_.device, &dl, nullptr, &p->setLayout) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
    VkPipelineLayoutCreateInfo pl = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pl.setLayoutCount = 1;
    pl.pSetLayouts = &p->setLayout;
    if (c_.f.vkCreatePipelineLayout(c_.device, &pl, nullptr, &p->layout) != VK_SUCCESS) { Set(status, Status::OutOfMemory); return nullptr; }
    VkShaderModule module = MakeModule(c_, desc.kernel.name);
    if (!module) { Set(status, Status::NotFound); return nullptr; }
    VkSpecializationMapEntry entries[3];
    for (uint32_t i = 0; i < 3; i++) entries[i] = { i, i * 4, 4 };
    VkSpecializationInfo spec = { 3, entries, sizeof(uint32_t) * 3, w };
    VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO };
    ci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    ci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    ci.stage.module = module;
    ci.stage.pName = "main";
    ci.stage.pSpecializationInfo = &spec;
    ci.layout = p->layout;
    VkResult r = c_.f.vkCreateComputePipelines(c_.device, VK_NULL_HANDLE, 1, &ci, nullptr, &p->pipeline);
    c_.f.vkDestroyShaderModule(c_.device, module, nullptr);
    if (r != VK_SUCCESS) { Set(status, Status::CompileFailed); return nullptr; }
    Set(status, Status::Ok);
    return std::unique_ptr<ComputePipeline>(p.release());
}

bool HasExtension(const std::vector<VkExtensionProperties> &list, const char *name)
{
    for (const VkExtensionProperties &e : list) if (std::strcmp(e.extensionName, name) == 0) return true;
    return false;
}

Status VulkanDevice::create(const VulkanOptions &options)
{
    c_.options = options;
    Functions &f = c_.f;
    if (!vk::LoadGlobal(f)) return Status::NotFound;
    uint32_t version = 0;
    if (f.vkEnumerateInstanceVersion(&version) != VK_SUCCESS || version < VK_API_VERSION_1_3) return Status::Unsupported;

    // Instance extensions and layers.
    uint32_t n = 0;
    f.vkEnumerateInstanceExtensionProperties(nullptr, &n, nullptr);
    std::vector<VkExtensionProperties> extensions(n);
    f.vkEnumerateInstanceExtensionProperties(nullptr, &n, extensions.data());
    std::vector<const char *> enabled;
    VkInstanceCreateFlags flags = 0;
    if (HasExtension(extensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        enabled.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    std::vector<const char *> layers;
    if (options.validation) {
        f.vkEnumerateInstanceLayerProperties(&n, nullptr);
        std::vector<VkLayerProperties> available(n);
        f.vkEnumerateInstanceLayerProperties(&n, available.data());
        bool found = false;
        for (const VkLayerProperties &l : available) found = found || std::strcmp(l.layerName, "VK_LAYER_KHRONOS_validation") == 0;
        if (!found) return Status::Unsupported;
        layers.push_back("VK_LAYER_KHRONOS_validation");
        if (!HasExtension(extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME)) return Status::Unsupported;
        enabled.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    }
    // Synchronisation validation is a setting of the validation layer (VK_EXT_layer_settings).
    VkBool32 on = VK_TRUE;
    VkLayerSettingEXT setting = { "VK_LAYER_KHRONOS_validation", "validate_sync", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &on };
    VkLayerSettingsCreateInfoEXT settings = { VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT };
    settings.settingCount = 1;
    settings.pSettings = &setting;
    VkDebugUtilsMessengerCreateInfoEXT messenger = { VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT };
    messenger.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    messenger.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                            VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    messenger.pfnUserCallback = DebugMessage;
    messenger.pUserData = &c_.options;
    if (options.validation && options.synchronizationValidation) {
        if (!HasExtension(extensions, VK_EXT_LAYER_SETTINGS_EXTENSION_NAME)) return Status::Unsupported;
        enabled.push_back(VK_EXT_LAYER_SETTINGS_EXTENSION_NAME);
        messenger.pNext = &settings;
    }
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "BorosKit";
    app.pEngineName = "BorosKit";
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ii.pNext = options.validation ? &messenger : nullptr;   // also reports problems during create / destroy
    ii.flags = flags;
    ii.pApplicationInfo = &app;
    ii.enabledExtensionCount = (uint32_t)enabled.size();
    ii.ppEnabledExtensionNames = enabled.data();
    ii.enabledLayerCount = (uint32_t)layers.size();
    ii.ppEnabledLayerNames = layers.data();
    if (f.vkCreateInstance(&ii, nullptr, &c_.instance) != VK_SUCCESS) return Status::NotFound;
    if (!vk::LoadInstance(f, c_.instance)) return Status::NotFound;
    if (options.validation) {
        messenger.pNext = nullptr;
        if (!f.vkCreateDebugUtilsMessengerEXT ||
            f.vkCreateDebugUtilsMessengerEXT(c_.instance, &messenger, nullptr, &c_.messenger) != VK_SUCCESS) return Status::Unsupported;
    }

    // GPU choice through BKGPUChoiceCore (the same rules as on Metal), among Vulkan 1.3 GPUs.
    f.vkEnumeratePhysicalDevices(c_.instance, &n, nullptr);
    std::vector<VkPhysicalDevice> physical(n);
    f.vkEnumeratePhysicalDevices(c_.instance, &n, physical.data());
    std::vector<VkPhysicalDevice> candidates;
    std::vector<VkPhysicalDeviceProperties> props;
    for (VkPhysicalDevice pd : physical) {
        VkPhysicalDeviceProperties p;
        f.vkGetPhysicalDeviceProperties(pd, &p);
        if (p.apiVersion < VK_API_VERSION_1_3) continue;
        candidates.push_back(pd);
        props.push_back(p);
    }
    if (candidates.empty()) return physical.empty() ? Status::NotFound : Status::Unsupported;
    std::vector<BKGPUAdapterDesc> adapters(candidates.size());
    for (size_t i = 0; i < candidates.size(); i++) {
        VkPhysicalDeviceMemoryProperties mp;
        f.vkGetPhysicalDeviceMemoryProperties(candidates[i], &mp);
        uint64_t local = 0;
        for (uint32_t h = 0; h < mp.memoryHeapCount; h++)
            if (mp.memoryHeaps[h].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) local += mp.memoryHeaps[h].size;
        BKGPUAdapterDesc &a = adapters[i];
        a.name = props[i].deviceName;
        a.vendorID = props[i].vendorID;
        switch (props[i].deviceType) {
            case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: a.kind = BKGPUKindDiscrete; break;
            case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: a.kind = BKGPUKindIntegrated; break;
            case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: a.kind = BKGPUKindVirtual; break;
            case VK_PHYSICAL_DEVICE_TYPE_CPU: a.kind = BKGPUKindCPU; break;
            default: a.kind = BKGPUKindUnknown; break;
        }
        a.isLowPower = a.kind == BKGPUKindIntegrated;
        a.isRemovable = 0;
        a.handle = (uint64_t)i;
        a.memoryBytes = local;
    }
    BKGPUChoiceStatus choice;
    int chosen = BKGPUChooseAdapter(adapters.data(), (int)adapters.size(), options.preferredName, &choice);
    if (chosen < 0) return Status::NotFound;
    c_.physical = candidates[(size_t)chosen];
    c_.properties = props[(size_t)chosen];
    c_.name = c_.properties.deviceName;
    VkPhysicalDeviceDriverProperties driver = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
    VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    p2.pNext = &driver;
    f.vkGetPhysicalDeviceProperties2(c_.physical, &p2);
    c_.driverName = driver.driverName;

    // One queue that can draw and compute.
    f.vkGetPhysicalDeviceQueueFamilyProperties(c_.physical, &n, nullptr);
    std::vector<VkQueueFamilyProperties> families(n);
    f.vkGetPhysicalDeviceQueueFamilyProperties(c_.physical, &n, families.data());
    bool haveQueue = false;
    for (uint32_t i = 0; i < n && !haveQueue; i++)
        if ((families[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) {
            c_.queueFamily = i;
            haveQueue = true;
        }
    if (!haveQueue) return Status::Unsupported;

    // Device: dynamic rendering (1.3), optional core features BorosKit can use, portability subset when offered.
    f.vkEnumerateDeviceExtensionProperties(c_.physical, nullptr, &n, nullptr);
    std::vector<VkExtensionProperties> deviceExtensions(n);
    f.vkEnumerateDeviceExtensionProperties(c_.physical, nullptr, &n, deviceExtensions.data());
    std::vector<const char *> deviceEnabled;
    if (HasExtension(deviceExtensions, "VK_KHR_portability_subset")) deviceEnabled.push_back("VK_KHR_portability_subset");
    VkPhysicalDeviceFeatures have;
    f.vkGetPhysicalDeviceFeatures(c_.physical, &have);
    VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    VkPhysicalDeviceFeatures2 query = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    query.pNext = &v13;
    f.vkGetPhysicalDeviceFeatures2(c_.physical, &query);
    if (!v13.dynamicRendering) return Status::Unsupported;
    VkPhysicalDeviceVulkan13Features want13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    want13.dynamicRendering = VK_TRUE;
    VkPhysicalDeviceFeatures2 want = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    want.pNext = &want13;
    want.features.independentBlend = have.independentBlend;
    want.features.fillModeNonSolid = have.fillModeNonSolid;
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qi.queueFamilyIndex = c_.queueFamily;
    qi.queueCount = 1;
    qi.pQueuePriorities = &priority;
    VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    di.pNext = &want;
    di.queueCreateInfoCount = 1;
    di.pQueueCreateInfos = &qi;
    di.enabledExtensionCount = (uint32_t)deviceEnabled.size();
    di.ppEnabledExtensionNames = deviceEnabled.data();
    if (f.vkCreateDevice(c_.physical, &di, nullptr, &c_.device) != VK_SUCCESS) return Status::Unsupported;
    if (!vk::LoadDevice(f, c_.device)) return Status::Unsupported;
    f.vkGetDeviceQueue(c_.device, c_.queueFamily, 0, &c_.queue);

    VkPhysicalDeviceMemoryProperties memory;
    f.vkGetPhysicalDeviceMemoryProperties(c_.physical, &memory);
    c_.allocator.init(&c_.f, c_.device, memory);

    // Limits (BKGPU.h): what passes may rely on.
    const VkPhysicalDeviceLimits &l = c_.properties.limits;
    limits_.maxBufferBytes = l.maxStorageBufferRange;
    limits_.maxStorageBufferRange = l.maxStorageBufferRange;
    limits_.maxImage2D = l.maxImageDimension2D;
    limits_.maxImage3D = l.maxImageDimension3D;
    limits_.maxComputeWorkgroupInvocations = l.maxComputeWorkGroupInvocations;
    for (int i = 0; i < 3; i++) limits_.maxComputeWorkgroupSize[i] = l.maxComputeWorkGroupSize[i];
    limits_.maxComputeSharedBytes = l.maxComputeSharedMemorySize;
    limits_.maxPushConstantBytes = l.maxPushConstantsSize;
    limits_.vendorID = c_.properties.vendorID;
    VkFormatProperties fp;
    f.vkGetPhysicalDeviceFormatProperties(c_.physical, VK_FORMAT_R16_UNORM, &fp);
    limits_.linearFilterR16Unorm3D = (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) != 0;
    f.vkGetPhysicalDeviceFormatProperties(c_.physical, VK_FORMAT_R32G32B32A32_SFLOAT, &fp);
    limits_.linearFilterRGBA32Float = (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) != 0;
    f.vkGetPhysicalDeviceFormatProperties(c_.physical, VK_FORMAT_R32_SFLOAT, &fp);
    limits_.linearFilterR32Float = (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT) != 0;
    f.vkGetPhysicalDeviceFormatProperties(c_.physical, VK_FORMAT_D32_SFLOAT, &fp);
    limits_.depth32Float = (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0;
    limits_.independentBlend = have.independentBlend != 0;
    limits_.wireframe = have.fillModeNonSolid != 0;
    limits_.timestamps = false;
    for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
        VkMemoryPropertyFlags fl = memory.memoryTypes[i].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) && (fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) limits_.unifiedMemory = true;
    }
    for (uint32_t h = 0; h < memory.memoryHeapCount; h++)
        if (memory.memoryHeaps[h].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) limits_.memoryBudgetBytes += memory.memoryHeaps[h].size;
    return Status::Ok;
}

}  // namespace

Status makeVulkanDevice(const VulkanOptions &options, std::unique_ptr<Device> *out)
{
    if (!out) return Status::InvalidArgument;
    std::unique_ptr<VulkanDevice> device(new VulkanDevice());
    Status s = device->create(options);
    if (s == Status::Ok) *out = std::move(device);
    return s;
}

Status makeVulkanDevice(const char *preferredName, std::unique_ptr<Device> *out)
{
    VulkanOptions options;
    options.preferredName = preferredName;
    return makeVulkanDevice(options, out);
}

const char *vulkanDriverName(const Device &device)
{
    const VulkanDevice *v = dynamic_cast<const VulkanDevice *>(&device);
    return v ? v->driverName() : "";
}

}  // namespace gpu
}  // namespace boroskit

namespace boroskit {
namespace gpu {

bool vulkanLoaderAvailable(const char **path)
{
    bool ok = vk::LoaderEntry() != nullptr;
    if (path) *path = vk::LoaderPath();
    return ok;
}

int vulkanBackendBuilt()
{
    return 1;
}

bool vulkanLoaderInstalled(const char **path)
{
    static std::string found;
    found = vk::FindLoaderFile();
    if (path) *path = found.c_str();
    return !found.empty();
}

}  // namespace gpu
}  // namespace boroskit
#endif   // BK_HAVE_VULKAN_HEADERS
