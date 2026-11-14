// BorosKitRender: BKMetalDevice - see include/BKMetalDevice.h (what, why, PORTING NOTES).
// Original BorosKit code written for this project; contains no third-party code.
// Compiled with ARC (BorosKitRender target).

#import "BKMetalDevice.h"
#import <TargetConditionals.h>

@interface BKGPUInfo ()
- (instancetype)initWithDevice:(id<MTLDevice>)device automatic:(BOOL)automatic;
@end

@implementation BKGPUInfo

- (instancetype)initWithDevice:(id<MTLDevice>)device automatic:(BOOL)automatic
{
    if (!(self = [super init])) return nil;
    _name = [device.name copy] ?: @"";
#if TARGET_OS_OSX
    _isLowPower = device.isLowPower;
    _isRemovable = device.isRemovable;
#endif
    _registryID = device.registryID;
    _memoryBytes = device.recommendedMaxWorkingSetSize;
    _isAutomaticChoice = automatic;
    if (_isRemovable) _displayName = [_name stringByAppendingString:@" (external)"];
    else if (_isLowPower) _displayName = [_name stringByAppendingString:@" (built-in)"];
    else _displayName = _name;
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<BKGPUInfo %@, %llu MB, registry 0x%llx%@>", _displayName,
            _memoryBytes / (1024ull * 1024ull), _registryID, _isAutomaticChoice ? @", automatic choice" : @""];
}

@end

// The preference string (guarded by the class object).
static NSString *BKPreferredGPUName = @"";

// Default Relaxed (2026-11-14): user approved "fast math off"; measured on M1 Pro (BKShaderMathBenchmark-
// Tests, 1024^2, 256^3 phantom): fast 1.55 ms / relaxed 1.55 ms / safe 5.1 ms per 3D frame (MIP 6.9 /
// 7.0 / 21.6 ms). Relaxed keeps infinity / NaN correct (the actual risk) at no cost; Safe is 3.3x slower.
static BKShaderMath gBKShaderMath = BKShaderMathRelaxed;

@implementation BKMetalDevice

+ (BKShaderMath)shaderMath { return gBKShaderMath; }
+ (void)setShaderMath:(BKShaderMath)shaderMath { gBKShaderMath = shaderMath; }

// What / why: see the header. macOS 15 / iOS 18 have the explicit math modes; older systems only
// the fast-math on/off switch (Relaxed then falls back to off, the safe side).
+ (MTLCompileOptions *)shaderCompileOptions
{
    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    if (@available(macOS 15.0, iOS 18.0, *)) {
        switch (gBKShaderMath) {
            case BKShaderMathFast:
                options.mathMode = MTLMathModeFast;
                options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
                break;
            case BKShaderMathRelaxed:
                options.mathMode = MTLMathModeRelaxed;
                options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
                break;
            default:
                options.mathMode = MTLMathModeSafe;
                options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
                break;
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        options.fastMathEnabled = (gBKShaderMath == BKShaderMathFast);
#pragma clang diagnostic pop
    }
    return options;
}

+ (void)setPreferredGPUName:(NSString *)name
{
    @synchronized (self) {
        BKPreferredGPUName = [name copy] ?: @"";
    }
}

+ (NSString *)preferredGPUName
{
    @synchronized (self) {
        return BKPreferredGPUName;
    }
}

// What: all Metal devices in the system's order (iOS: the one system device).
+ (NSArray<id<MTLDevice>> *)allDevices
{
#if TARGET_OS_OSX
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if (devices.count > 0) return devices;
#endif
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device ? @[device] : @[];
}

// What: maps the devices onto the plain-C descriptions and runs the shared chooser.
// The name strings stay alive in `devices` while the C function runs.
+ (NSInteger)chooseIndexIn:(NSArray<id<MTLDevice>> *)devices preference:(NSString *)preference
                    status:(BKGPUChoiceStatus *)status
{
    int count = (int)devices.count;
    if (count == 0) {
        if (status) *status = BKGPUChoiceNone;
        return -1;
    }
    BKGPUAdapterDesc *descs = calloc((size_t)count, sizeof(BKGPUAdapterDesc));
    if (descs == NULL) {
        if (status) *status = BKGPUChoiceAutomatic;
        return 0;
    }
    for (int i = 0; i < count; i++) {
        id<MTLDevice> d = devices[i];
        descs[i].name = d.name.UTF8String;
        descs[i].vendorID = 0;   // Metal does not report the PCI vendor
        descs[i].kind = BKGPUKindUnknown;
#if TARGET_OS_OSX
        descs[i].isLowPower = d.isLowPower ? 1 : 0;
        descs[i].isRemovable = d.isRemovable ? 1 : 0;
#endif
        descs[i].handle = d.registryID;
        descs[i].memoryBytes = d.recommendedMaxWorkingSetSize;
    }
    int index = BKGPUChooseAdapter(descs, count, preference.UTF8String, status);
    free(descs);
    return index;
}

+ (id<MTLDevice>)preferredDeviceWithStatus:(BKGPUChoiceStatus *)status
{
    NSArray<id<MTLDevice>> *devices = [self allDevices];
    NSInteger index = [self chooseIndexIn:devices preference:[self preferredGPUName] status:status];
    return index >= 0 ? devices[(NSUInteger)index] : nil;
}

+ (id<MTLDevice>)preferredDevice
{
    return [self preferredDeviceWithStatus:NULL];
}

+ (NSArray<BKGPUInfo *> *)availableGPUs
{
    NSArray<id<MTLDevice>> *devices = [self allDevices];
    NSInteger automatic = [self chooseIndexIn:devices preference:@"" status:NULL];
    NSMutableArray<BKGPUInfo *> *infos = [NSMutableArray arrayWithCapacity:devices.count];
    [devices enumerateObjectsUsingBlock:^(id<MTLDevice> d, NSUInteger i, BOOL *stop) {
        [infos addObject:[[BKGPUInfo alloc] initWithDevice:d automatic:(NSInteger)i == automatic]];
    }];
    return infos;
}

+ (NSString *)logDescriptionForDevice:(id<MTLDevice>)device
{
    NSString *preference = [self preferredGPUName];
    NSString *name = device ? device.name : @"no Metal GPU";
    if (preference.length == 0)
        return [NSString stringWithFormat:@"%@ (preference: Automatic)", name];
    BKGPUChoiceStatus status = BKGPUChoiceNone;
    [self preferredDeviceWithStatus:&status];
    if (status == BKGPUChoicePreferredMissing)
        return [NSString stringWithFormat:@"%@ (preference: %@ - not present, using Automatic)", name, preference];
    return [NSString stringWithFormat:@"%@ (preference: %@)", name, preference];
}

@end
