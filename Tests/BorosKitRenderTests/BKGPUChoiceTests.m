// Tests for the graphics-card choice: the plain-C chooser (BKGPUChoiceCore.h) with made-up
// adapter lists (Mac laptops, Mac Pro, eGPU, Vulkan-style NVIDIA/AMD/Intel/CPU lists), and the
// Metal layer (BKMetalDevice.h) on whatever GPU the test machine has.
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import "BKGPUChoiceCore.h"
#import "BKMetalDevice.h"

@interface BKGPUChoiceTests : XCTestCase
@end

static BKGPUAdapterDesc BKAdapter(const char *name, int kind, int lowPower, int removable,
                                  uint64_t handle, uint64_t memoryMB)
{
    BKGPUAdapterDesc d;
    d.name = name;
    d.vendorID = 0;
    d.kind = kind;
    d.isLowPower = lowPower;
    d.isRemovable = removable;
    d.handle = handle;
    d.memoryBytes = memoryMB * 1024ull * 1024ull;
    return d;
}

@implementation BKGPUChoiceTests

- (void)tearDown
{
    [BKMetalDevice setPreferredGPUName:nil];   // other tests expect Automatic
    [super tearDown];
}

// Empty list: -1 and status None, whatever the preference.
- (void)testEmptyList
{
    BKGPUChoiceStatus status = BKGPUChoiceAutomatic;
    XCTAssertEqual(BKGPUChooseAdapter(NULL, 0, "", &status), -1);
    XCTAssertEqual(status, BKGPUChoiceNone);
    XCTAssertEqual(BKGPUChooseAdapter(NULL, 0, "Any", NULL), -1);
}

// MacBook Pro 2019 (Metal style: kind unknown): Automatic = the discrete AMD, not the low-power
// Intel; a name picks exactly that card.
- (void)testLaptopIntegratedPlusDiscrete
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter("Intel(R) UHD Graphics 630", BKGPUKindUnknown, 1, 0, 0x100, 1536),
        BKAdapter("AMD Radeon Pro 5500M", BKGPUKindUnknown, 0, 0, 0x200, 4096),
    };
    BKGPUChoiceStatus status;
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", &status), 1);
    XCTAssertEqual(status, BKGPUChoiceAutomatic);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, NULL, &status), 1);
    XCTAssertEqual(status, BKGPUChoiceAutomatic);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "Intel(R) UHD Graphics 630", &status), 0);
    XCTAssertEqual(status, BKGPUChoiceByName);
}

// External GPU: Automatic never picks it (even with more memory); by name it is used; when it is
// unplugged the name is missing -> Automatic, status PreferredMissing.
- (void)testExternalGPUOnlyWhenChosen
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter("Intel(R) Iris(TM) Plus Graphics", BKGPUKindUnknown, 1, 0, 0x10, 1536),
        BKAdapter("AMD Radeon RX 6800 XT", BKGPUKindUnknown, 0, 1, 0x20, 16384),
    };
    BKGPUChoiceStatus status;
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", &status), 0);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "AMD Radeon RX 6800 XT", &status), 1);
    XCTAssertEqual(status, BKGPUChoiceByName);

    // unplugged: only the built-in card is listed
    XCTAssertEqual(BKGPUChooseAdapter(list, 1, "AMD Radeon RX 6800 XT", &status), 0);
    XCTAssertEqual(status, BKGPUChoicePreferredMissing);
}

// Only a removable card present: Automatic still has to use it.
- (void)testOnlyRemovable
{
    BKGPUAdapterDesc list[1] = { BKAdapter("eGPU", BKGPUKindUnknown, 0, 1, 1, 8192) };
    XCTAssertEqual(BKGPUChooseAdapter(list, 1, "", NULL), 0);
}

// Name match is exact (case and spaces count); a near miss is "missing".
- (void)testExactNameMatch
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter("Apple M2 Max", BKGPUKindUnknown, 0, 0, 1, 49152),
        BKAdapter("Apple M2", BKGPUKindUnknown, 0, 0, 2, 16384),
    };
    BKGPUChoiceStatus status;
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "Apple M2", &status), 1);
    XCTAssertEqual(status, BKGPUChoiceByName);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "apple m2", &status), 0);   // Automatic: more memory
    XCTAssertEqual(status, BKGPUChoicePreferredMissing);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "Apple M2 ", &status), 0);
    XCTAssertEqual(status, BKGPUChoicePreferredMissing);
}

// Mac Pro with two identical cards plus a third: by name, the better (more memory, then smaller
// handle) of the two identical ones; result does not depend on list order.
- (void)testIdenticalNamesDeterministic
{
    BKGPUAdapterDesc a = BKAdapter("AMD Radeon Pro W6800X", BKGPUKindUnknown, 0, 0, 0x30, 32768);
    BKGPUAdapterDesc b = BKAdapter("AMD Radeon Pro W6800X", BKGPUKindUnknown, 0, 0, 0x20, 32768);
    BKGPUAdapterDesc c = BKAdapter("AMD Radeon Pro W5700X", BKGPUKindUnknown, 0, 0, 0x10, 16384);
    BKGPUAdapterDesc order1[3] = { a, b, c };
    BKGPUAdapterDesc order2[3] = { c, b, a };
    XCTAssertEqual(order1[BKGPUChooseAdapter(order1, 3, "AMD Radeon Pro W6800X", NULL)].handle, 0x20u);
    XCTAssertEqual(order2[BKGPUChooseAdapter(order2, 3, "AMD Radeon Pro W6800X", NULL)].handle, 0x20u);
    // Automatic: largest memory first, then smaller handle
    XCTAssertEqual(order1[BKGPUChooseAdapter(order1, 3, "", NULL)].handle, 0x20u);
    XCTAssertEqual(order2[BKGPUChooseAdapter(order2, 3, "", NULL)].handle, 0x20u);
}

// Fully equal adapters (same handle and name): the earlier list position wins.
- (void)testFullTieKeepsListOrder
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter("Same", BKGPUKindUnknown, 0, 0, 7, 1024),
        BKAdapter("Same", BKGPUKindUnknown, 0, 0, 7, 1024),
    };
    XCTAssertEqual(BKGPUCompareForAutomatic(&list[0], &list[1]), 0);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", NULL), 0);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "Same", NULL), 0);
}

// Vulkan-style list (kind reported): discrete NVIDIA beats integrated Intel even with less memory;
// the software CPU device is last even though it reports the most memory; virtual is after
// integrated.
- (void)testVulkanStyleKinds
{
    BKGPUAdapterDesc list[4] = {
        BKAdapter("llvmpipe (LLVM 15.0.7, 256 bits)", BKGPUKindCPU, 0, 0, 1, 65536),
        BKAdapter("Intel(R) UHD Graphics 770", BKGPUKindIntegrated, 1, 0, 2, 32768),
        BKAdapter("NVIDIA GeForce RTX 4070", BKGPUKindDiscrete, 0, 0, 3, 12288),
        BKAdapter("Virtual GPU", BKGPUKindVirtual, 0, 0, 4, 8192),
    };
    list[1].vendorID = 0x8086;
    list[2].vendorID = 0x10DE;
    XCTAssertEqual(BKGPUChooseAdapter(list, 4, "", NULL), 2);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", NULL), 1);      // CPU + integrated -> integrated
    BKGPUAdapterDesc soft[2] = { list[0], list[3] };
    XCTAssertEqual(BKGPUChooseAdapter(soft, 2, "", NULL), 1);      // virtual before CPU
    XCTAssertEqual(BKGPUChooseAdapter(list, 4, "llvmpipe (LLVM 15.0.7, 256 bits)", NULL), 0);
}

// NVIDIA + AMD discrete: more memory wins in Automatic; each can be chosen by name.
- (void)testTwoDiscreteVendors
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter("NVIDIA GeForce RTX 3060", BKGPUKindDiscrete, 0, 0, 1, 12288),
        BKAdapter("AMD Radeon RX 7900 XTX", BKGPUKindDiscrete, 0, 0, 2, 24576),
    };
    list[0].vendorID = 0x10DE;
    list[1].vendorID = 0x1002;
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", NULL), 1);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "NVIDIA GeForce RTX 3060", NULL), 0);
}

// NULL names are treated as "" and never match a real preference.
- (void)testNullName
{
    BKGPUAdapterDesc list[2] = {
        BKAdapter(NULL, BKGPUKindUnknown, 0, 0, 1, 1024),
        BKAdapter("Named", BKGPUKindUnknown, 1, 0, 2, 1024),
    };
    BKGPUChoiceStatus status;
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "Named", &status), 1);
    XCTAssertEqual(BKGPUChooseAdapter(list, 2, "", &status), 0);
}

#pragma mark - Metal layer (runs on the test machine's real GPUs)

// Automatic returns a device that is in the list and flagged as the automatic choice; every
// card listed can be chosen by name; an unknown name falls back to Automatic.
- (void)testMetalLayer
{
    NSArray<BKGPUInfo *> *gpus = [BKMetalDevice availableGPUs];
    if (gpus.count == 0) { NSLog(@"BKGPUChoiceTests: no Metal GPU, skipped"); return; }

    [BKMetalDevice setPreferredGPUName:@""];
    BKGPUChoiceStatus status = BKGPUChoiceNone;
    id<MTLDevice> automatic = [BKMetalDevice preferredDeviceWithStatus:&status];
    XCTAssertNotNil(automatic);
    XCTAssertEqual(status, BKGPUChoiceAutomatic);
    NSUInteger flagged = 0;
    for (BKGPUInfo *gpu in gpus) {
        if (gpu.isAutomaticChoice) {
            flagged++;
            XCTAssertEqual(gpu.registryID, automatic.registryID);
        }
        XCTAssertTrue([gpu.displayName hasPrefix:gpu.name]);
    }
    XCTAssertEqual(flagged, 1u);
    XCTAssertEqualObjects([BKMetalDevice logDescriptionForDevice:automatic],
                          ([NSString stringWithFormat:@"%@ (preference: Automatic)", automatic.name]));

    for (BKGPUInfo *gpu in gpus) {
        [BKMetalDevice setPreferredGPUName:gpu.name];
        id<MTLDevice> chosen = [BKMetalDevice preferredDeviceWithStatus:&status];
        XCTAssertEqual(status, BKGPUChoiceByName);
        XCTAssertEqualObjects(chosen.name, gpu.name);
    }

    [BKMetalDevice setPreferredGPUName:@"No Such GPU 9000"];
    id<MTLDevice> fallback = [BKMetalDevice preferredDeviceWithStatus:&status];
    XCTAssertEqual(status, BKGPUChoicePreferredMissing);
    XCTAssertEqual(fallback.registryID, automatic.registryID);
    XCTAssertTrue([[BKMetalDevice logDescriptionForDevice:fallback] containsString:@"not present, using Automatic"]);
    XCTAssertEqualObjects([BKMetalDevice preferredGPUName], @"No Such GPU 9000");

    [BKMetalDevice setPreferredGPUName:nil];
    XCTAssertEqualObjects([BKMetalDevice preferredGPUName], @"");
}

@end
