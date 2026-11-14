// BorosKitRender: BKGPUChoiceCore (plain C, backend-neutral choice of the graphics card)
// Original BorosKit code written for this project; contains no third-party code.
//
// What it is: given a list of the graphics cards ("adapters") the system reports and the user's
// preference (a card NAME, or "" for Automatic), pick the one card BorosKit draws with.
//   - Preference = a name: the card whose name matches exactly (byte for byte). If several cards
//     have that name (two identical cards), the best of them by the Automatic order below.
//   - Preference = "" (or NULL), or the named card is not present (e.g. an unplugged external
//     GPU): Automatic, and the status says which of the two happened, so the caller can log it.
//   - Automatic order (first difference decides, so the result never depends on list order):
//       1. real GPUs before software renderers (kind CPU);
//       2. built-in before removable (an external GPU is used only when chosen by name);
//       3. discrete / high-performance before integrated / low-power, then virtual GPUs;
//       4. more memory first;
//       5. smaller handle first, then name (strcmp), then position in the list.
// Why plain C: the Metal layer (BKMetalDevice.m) only lists MTLDevices and maps them onto
// BKGPUAdapterDesc; a future Vulkan backend lists VkPhysicalDevices and calls this same function,
// so one preference string picks the same card on every backend.
//
// ---- PORTING NOTES (future Vulkan backend, CUDA / ROCm accelerator packs) ---------------
//  - C99 + libc only (string.h). No Foundation, Metal or Vulkan types.
//  - Vulkan mapping, one BKGPUAdapterDesc per VkPhysicalDevice (vkEnumeratePhysicalDevices,
//    vkGetPhysicalDeviceProperties / ...MemoryProperties):
//      name        = VkPhysicalDeviceProperties.deviceName (UTF-8; the string the user picked)
//      vendorID    = VkPhysicalDeviceProperties.vendorID (0x10DE NVIDIA, 0x1002 AMD,
//                    0x8086 Intel, 0x106B Apple); Metal does not report it and passes 0
//      kind        = deviceType: DISCRETE_GPU -> BKGPUKindDiscrete, INTEGRATED_GPU ->
//                    BKGPUKindIntegrated, VIRTUAL_GPU -> BKGPUKindVirtual, CPU -> BKGPUKindCPU,
//                    OTHER -> BKGPUKindUnknown
//      isLowPower  = 1 for INTEGRATED_GPU (Vulkan has no separate flag), else 0
//      isRemovable = Vulkan has no portable flag: 0, unless the platform tells (e.g. on macOS
//                    through MoltenVK's MTLDevice, or Thunderbolt-attached on Windows/Linux)
//      handle      = the device's index or a hash of deviceUUID (VkPhysicalDeviceIDProperties);
//                    only used to break ties, so it must be stable for one run
//      memoryBytes = sum of the DEVICE_LOCAL heaps (for integrated GPUs: the shared heap)
//  - Two identical cards share a name; the name preference then picks the first by the order
//    above. If the user ever needs to pick one of two identical cards, extend the preference to
//    "name#n" or a deviceUUID; keep "" = Automatic and plain names working.
//  - The CUDA (NVIDIA) and ROCm/HIP (AMD) accelerator packs of the BorosAI plug-in should read
//    the same preference (user default BorosPreferredGPU) and match it against the card name
//    their runtime reports (cudaGetDeviceProperties.name / hipDeviceProp_t.name), so AI runs on
//    the same card that draws. When the preferred card is not theirs (other vendor), they use
//    Automatic among their own cards.
// ---------------------------------------------------------------------------------------

#ifndef BK_GPU_CHOICE_CORE_H
#define BK_GPU_CHOICE_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What kind of adapter it is (Vulkan's VkPhysicalDeviceType, see PORTING NOTES).
typedef enum {
    BKGPUKindUnknown    = 0,   // not reported (Metal): isLowPower decides discrete vs integrated
    BKGPUKindDiscrete   = 1,
    BKGPUKindIntegrated = 2,
    BKGPUKindVirtual    = 3,
    BKGPUKindCPU        = 4,   // software renderer (e.g. a CPU Vulkan driver)
} BKGPUKind;

// One graphics card as the backend reports it. The chooser never keeps the pointers.
typedef struct {
    const char *name;          // UTF-8 card name, as shown to the user (NULL treated as "")
    uint32_t vendorID;         // PCI vendor ID, 0 = unknown
    int32_t kind;              // BKGPUKind
    int32_t isLowPower;        // 1 = power-saving GPU (integrated), 0 = high-performance or unknown
    int32_t isRemovable;       // 1 = external / removable (eGPU)
    uint64_t handle;           // backend's stable id (Metal registryID), tie-break only
    uint64_t memoryBytes;      // usable GPU memory (Metal recommendedMaxWorkingSetSize)
} BKGPUAdapterDesc;

// How the choice was made (for the caller's log line).
typedef enum {
    BKGPUChoiceNone             = 0,   // empty list: no GPU (return value is -1)
    BKGPUChoiceAutomatic        = 1,   // preference was Automatic ("" / NULL)
    BKGPUChoiceByName           = 2,   // the named card was found
    BKGPUChoicePreferredMissing = 3,   // the named card is not present: Automatic was used
} BKGPUChoiceStatus;

// What: Automatic order of two adapters. < 0 = a is better, > 0 = b is better, 0 = same on
// every criterion except list position (the chooser then keeps the earlier one).
int BKGPUCompareForAutomatic(const BKGPUAdapterDesc *a, const BKGPUAdapterDesc *b);

// What: index of the adapter to use, or -1 when count is 0. preferredName = "" or NULL means
// Automatic. status (may be NULL) receives how the choice was made.
int BKGPUChooseAdapter(const BKGPUAdapterDesc *adapters, int count, const char *preferredName,
                       BKGPUChoiceStatus *status);

#ifdef __cplusplus
}
#endif

#endif
