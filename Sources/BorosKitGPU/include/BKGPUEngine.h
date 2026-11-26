// BorosKitGPU: BKGPUEngine.h - which GPU engine NEW BorosKit renderers use: native Metal (always the default) or, as a
// TEST, the Vulkan engine through MoltenVK.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (user request: "mac should stay on native metal but we need the switch
// to test").
//
// PORTING NOTES / how it works:
//   - Default and normal use: Metal, exactly as before - nothing below runs, nothing changes.
//   - Test mode (+setPreferredEngine:BKGPUEngineVulkanTest): renderers created AFTERWARDS (BKVolumeRenderer,
//     BKCurvedReformat, BKSurfaceExtractor, BKMeshRenderer, BKImageLayerRenderer, BKOverlayRenderer) run their shared
//     passes on ONE process-wide Vulkan device (MoltenVK) instead of their MetalDevice. Their inputs are copied from
//     the Metal objects (BKGPUEngineBridge.h), results are read back and written into the caller's Metal buffers /
//     textures, so the app keeps presenting with Metal. Speed is not the goal; a fair picture comparison is.
//   - Vulkan is never bundled or required: the engine exists only after the app registered it
//     (BKGPUVulkanTestEngineInstall, product BorosKitGPUVulkan) AND the user's installed Vulkan SDK loader was found.
//   - On-screen pictures made by the Vulkan engine carry a small "Vulkan (MoltenVK)" marker (bottom-right).
//   - Console: "Boros GPU engine: ..." lines (which engine each renderer uses; frame times in test mode).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKGPUEngineKind) {
    BKGPUEngineMetal = 0,          // native Metal (default)
    BKGPUEngineVulkanTest = 1,     // the Vulkan engine through MoltenVK, for comparison tests only
};

@interface BKGPUEngine : NSObject

// What: the engine renderers created from now on use (open windows keep theirs). Metal by default.
+ (void)setPreferredEngine:(BKGPUEngineKind)engine;
+ (BKGPUEngineKind)preferredEngine;

// What: YES when the Vulkan test engine can be used on this Mac: registered by the app, built with the Vulkan SDK
// headers, the SDK's loader found and a device started. reason (may be NULL) gets a one-line explanation when NO.
// The first call may take a moment (it starts the device once).
+ (BOOL)vulkanTestEngineAvailable:(NSString *_Nullable *_Nullable)reason;

// What: the same question WITHOUT starting or loading anything (the installed SDK's loader file is looked for) - for
// settings screens, so merely showing the choice never loads Vulkan into the app.
+ (BOOL)vulkanTestEngineInstalled:(NSString *_Nullable *_Nullable)reason;

// What: a short description of the engine a renderer made NOW would use, e.g. "Metal" or
// "Vulkan (MoltenVK) on Apple M1 Pro, loader /usr/local/lib/libvulkan.1.dylib".
+ (NSString *)currentEngineDescription;

@end

NS_ASSUME_NONNULL_END
