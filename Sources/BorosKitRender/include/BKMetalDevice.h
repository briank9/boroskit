// BorosKitRender: BKMetalDevice - which graphics card (MTLDevice) BorosKit draws with.
// Original BorosKit code written for this project; contains no third-party code.
//
// What: every BorosKit Metal class that needs a device and was given none (renderers, scenes,
// views, the surface extractor) calls +[BKMetalDevice preferredDevice] instead of
// MTLCreateSystemDefaultDevice(). The app hands the user's choice in once with
// +setPreferredGPUName: (Boros 6: Settings > General "Graphics card", user default
// BorosPreferredGPU = the card NAME, "" = Automatic). The choice itself is made by the plain-C
// BKGPUChooseAdapter (BKGPUChoiceCore.h); this class only lists the Metal devices and maps them.
// Why: Macs with two or more GPUs (MacBook Pro integrated + discrete, Mac Pro, external GPUs) let
// the user pick the card; a name is used (not an index or registry id) because it stays the same
// across restarts, machines and the future Vulkan backend.
// A preferred card that is not present (unplugged eGPU) falls back to Automatic; the status /
// +logDescriptionForDevice: say so, so the app can write it to Console.
//
// ---- PORTING NOTES (future Vulkan backend) -------------------------------------------
//  - This file is the Metal half only. The Vulkan backend gets a twin (e.g. BKVulkanDevice) that
//    enumerates VkPhysicalDevices, fills one BKGPUAdapterDesc per device exactly as described in
//    BKGPUChoiceCore.h (deviceType DISCRETE/INTEGRATED, vendorID 0x10DE NVIDIA / 0x1002 AMD /
//    0x8086 Intel, deviceName) and calls the same BKGPUChooseAdapter with the same preference
//    string, so "Automatic" and a chosen name mean the same on both backends.
//  - Metal -> BKGPUAdapterDesc: name = device.name, vendorID = 0 (Metal does not report it),
//    kind = Unknown (isLowPower decides), isLowPower = device.isLowPower, isRemovable =
//    device.isRemovable, handle = device.registryID, memoryBytes =
//    device.recommendedMaxWorkingSetSize. iOS/iPadOS has one GPU: always the system device.
//  - The CUDA / ROCm accelerator packs read the same preference (see BKGPUChoiceCore.h).
// ---------------------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "BKGPUChoiceCore.h"

NS_ASSUME_NONNULL_BEGIN

// One graphics card as offered to the user (Settings popup) and logged.
@interface BKGPUInfo : NSObject
@property (nonatomic, readonly, copy) NSString *name;          // device.name: the value to store
@property (nonatomic, readonly, copy) NSString *displayName;   // name + " (built-in)" for a
                                                               // low-power GPU, " (external)" for a
                                                               // removable one
@property (nonatomic, readonly) BOOL isLowPower;
@property (nonatomic, readonly) BOOL isRemovable;
@property (nonatomic, readonly) uint64_t registryID;
@property (nonatomic, readonly) uint64_t memoryBytes;
@property (nonatomic, readonly) BOOL isAutomaticChoice;        // the card Automatic would pick now
@end

@interface BKMetalDevice : NSObject

// What: the user's preferred card name; nil or "" = Automatic. Thread-safe. Affects devices
// handed out afterwards only (objects already made keep their device).
+ (void)setPreferredGPUName:(nullable NSString *)name;
+ (NSString *)preferredGPUName;   // "" = Automatic

// What: the device to use now (preference, else Automatic). nil only when the machine has no
// Metal GPU at all. Not +1 (normal Cocoa naming); the system keeps one object per card.
+ (nullable id<MTLDevice>)preferredDevice;
// Same, also telling how the choice was made (status may be NULL).
+ (nullable id<MTLDevice>)preferredDeviceWithStatus:(nullable BKGPUChoiceStatus *)status;

// What: every card Metal reports, in the system's order. Empty when there is no GPU.
+ (NSArray<BKGPUInfo *> *)availableGPUs;

// What: one line for the app's Console log, e.g.
//   "AMD Radeon Pro 5500M (preference: Automatic)"
//   "Apple M2 Max (preference: Radeon RX 6800 XT - not present, using Automatic)"
// device = the device actually used (nil -> "no Metal GPU").
+ (NSString *)logDescriptionForDevice:(nullable id<MTLDevice>)device;

@end

NS_ASSUME_NONNULL_END
