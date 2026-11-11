// BorosKitRender: BKPresetLoader implementation (see BKPresetLoader.h for the why).

#import "BKPresetLoader.h"
#import "BKPreset.h"

NSErrorDomain const BKPresetErrorDomain = @"BKPresetErrorDomain";

// Names Horos treats specially (stored untranslated in the built-in preset files).
static NSString * const BKNoCLUTName = @"No CLUT";
static NSString * const BKLinearOpacityName = @"Linear Table";
static NSString * const BK16BitCLUTName = @"16-bit CLUT";

// Makes an NSError in the preset domain with a plain-language message.
static NSError *BKPresetError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:BKPresetErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Reads a number that may be stored as NSNumber or NSString (Horos uses both).
static BOOL BKReadFloat(id object, float *value)
{
    if ([object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSString class]]) {
        *value = [object floatValue];
        return YES;
    }
    return NO;
}

// Formats a point the way NSStringFromPoint does ("{x, y}"), so tables generated here
// look exactly like the ones Horos keeps in its user defaults.
static NSString *BKPointString(double x, double y)
{
    return [NSString stringWithFormat:@"{%.17g, %.17g}", x, y];
}

@implementation BKPresetLoader {
    NSMutableDictionary<NSString *, NSDictionary *> *_opacityTables;
    NSMutableArray<NSDictionary *> *_shadingPresets;
}

// Builds the three opacity tables Horos registers in DefaultsOsiriX.m (same formulas,
// same 1000 offset on x), so built-in presets resolve without the Mac app's defaults.
+ (NSDictionary<NSString *, NSDictionary *> *)builtInOpacityTables
{
    NSMutableArray *log = [NSMutableArray array], *logInverse = [NSMutableArray array];
    for (int i = 0; i < 256; i++) {
        [log addObject:BKPointString(1000 + i, log10(1. + (i / 255.) * 9.))];
        [logInverse addObject:BKPointString(1000 + i, 1. - log10(1. + ((255 - i) / 255.) * 9.))];
    }
    return @{
        @"Logarithmic Table": @{@"Points": log},
        @"Logarithmic Inverse Table": @{@"Points": logInverse},
        @"Smooth Table": @{@"Points": @[BKPointString(1000 + 180, 0.05)]},
    };
}

// The four lighting presets Horos registers in DefaultsOsiriX.m ("shadingsPresets").
+ (NSArray<NSDictionary *> *)builtInShadingPresets
{
    return @[
        @{@"name": @"Default",         @"ambient": @"0.15", @"diffuse": @"0.9",  @"specular": @"0.3",  @"specularPower": @"15"},
        @{@"name": @"Glossy Vascular", @"ambient": @"0.15", @"diffuse": @"0.28", @"specular": @"1.42", @"specularPower": @"50"},
        @{@"name": @"Glossy Bone",     @"ambient": @"0.15", @"diffuse": @"0.24", @"specular": @"1.17", @"specularPower": @"6.98"},
        @{@"name": @"Endoscopy",       @"ambient": @"0.12", @"diffuse": @"0.64", @"specular": @"0.73", @"specularPower": @"50"},
    ];
}

// A loader that knows Horos' built-in opacity tables and lighting; CLUT folders are
// added by the caller because their location depends on the app / device.
- (instancetype)init
{
    if ((self = [super init])) {
        _clutDirectories = @[];
        _opacityTables = [[[self class] builtInOpacityTables] mutableCopy];
        _shadingPresets = [[[self class] builtInShadingPresets] mutableCopy];
    }
    return self;
}

- (NSDictionary<NSString *, NSDictionary *> *)opacityTables { return [_opacityTables copy]; }
- (NSArray<NSDictionary *> *)shadingPresets { return [_shadingPresets copy]; }

// Merges in the user's opacity tables (same name replaces the built-in one, like Horos
// where the user default simply holds the current set).
- (void)addOpacityTables:(NSDictionary<NSString *, NSDictionary *> *)tables
{
    [_opacityTables addEntriesFromDictionary:tables];
}

// Merges in lighting presets; a preset with an existing name replaces it.
- (void)addShadingPresets:(NSArray<NSDictionary *> *)presets
{
    for (NSDictionary *preset in presets) {
        NSString *name = preset[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        NSUInteger existing = [_shadingPresets indexOfObjectPassingTest:^BOOL(NSDictionary *d, NSUInteger i, BOOL *stop) {
            return [d[@"name"] isEqual:name];
        }];
        if (existing != NSNotFound) _shadingPresets[existing] = preset;
        else [_shadingPresets addObject:preset];
    }
}

+ (BOOL)parsePointString:(NSString *)string point:(CGPoint *)point
{
    // NSPointFromString is AppKit-only (and NSScanner keeps this tolerant of spacing).
    NSScanner *scanner = [NSScanner scannerWithString:string];
    double x, y;
    if (![scanner scanString:@"{" intoString:NULL]) return NO;
    if (![scanner scanDouble:&x]) return NO;
    if (![scanner scanString:@"," intoString:NULL]) return NO;
    if (![scanner scanDouble:&y]) return NO;
    if (![scanner scanString:@"}" intoString:NULL]) return NO;
    *point = CGPointMake(x, y);
    return YES;
}

// Finds "<name>.plist" in the CLUT folders (first match wins) and reads it.
- (nullable NSDictionary *)clutDictionaryNamed:(NSString *)name
{
    NSString *fileName = [name stringByAppendingPathExtension:@"plist"];
    for (NSURL *directory in _clutDirectories) {
        NSURL *url = [directory URLByAppendingPathComponent:fileName];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfURL:url];
        if (dict) return dict;
    }
    return nil;
}

// Converts one 256-entry Red/Green/Blue array into bytes, clamped to 0..255.
static NSData *BKCLUTChannel(id array)
{
    if (![array isKindOfClass:[NSArray class]] || [array count] < 256) return nil;
    uint8_t bytes[256];
    for (int i = 0; i < 256; i++) {
        float v = 0;
        if (!BKReadFloat(array[i], &v)) return nil;
        bytes[i] = (uint8_t)fminf(fmaxf(roundf(v), 0), 255);
    }
    return [NSData dataWithBytes:bytes length:256];
}

- (BOOL)getCLUTNamed:(NSString *)name red:(NSData **)red green:(NSData **)green blue:(NSData **)blue
{
    *red = *green = *blue = nil;
    if (name.length == 0 || [name isEqualToString:BKNoCLUTName]) return NO;
    NSDictionary *clut = [self clutDictionaryNamed:name];
    NSData *r = BKCLUTChannel(clut[@"Red"]), *g = BKCLUTChannel(clut[@"Green"]), *b = BKCLUTChannel(clut[@"Blue"]);
    if (!r || !g || !b) return NO;
    *red = r; *green = g; *blue = b;
    return YES;
}

// Reads Horos' advanced-CLUT curves: `curves` = array of arrays of {x, y} dictionaries,
// `colors` = matching arrays of {red, green, blue} dictionaries (0..1). This is the
// same data CLUTOpacityView's convertCurvesFromPlist / convertPointColorsFromPlist read.
static NSArray<BKPresetCurve *> *BKParseCurves(id curves, id colors, NSMutableArray<NSString *> *warnings)
{
    if (![curves isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger c = 0; c < [curves count]; c++) {
        NSArray *curve = curves[c];
        NSArray *curveColors = ([colors isKindOfClass:[NSArray class]] && c < [colors count]) ? colors[c] : nil;
        if (![curve isKindOfClass:[NSArray class]]) continue;
        if (curveColors.count != curve.count)
            [warnings addObject:[NSString stringWithFormat:@"Curve %lu has %lu points but %lu colours; missing colours are white.",
                                 (unsigned long)c, (unsigned long)curve.count, (unsigned long)curveColors.count]];
        NSMutableData *points = [NSMutableData data];
        for (NSUInteger i = 0; i < curve.count; i++) {
            NSDictionary *pt = curve[i];
            BKPresetCurvePoint p = {0, 0, 1, 1, 1};
            if (![pt isKindOfClass:[NSDictionary class]] || !BKReadFloat(pt[@"x"], &p.value) || !BKReadFloat(pt[@"y"], &p.level))
                continue;
            NSDictionary *color = i < curveColors.count ? curveColors[i] : nil;
            if ([color isKindOfClass:[NSDictionary class]]) {
                BKReadFloat(color[@"red"], &p.red);
                BKReadFloat(color[@"green"], &p.green);
                BKReadFloat(color[@"blue"], &p.blue);
            }
            [points appendBytes:&p length:sizeof(p)];
        }
        if (points.length)
            [result addObject:[[BKPresetCurve alloc] initWithPoints:points.bytes count:points.length / sizeof(BKPresetCurvePoint)]];
    }
    return result;
}

- (BKPreset *)presetWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        if (error && plist) *error = BKPresetError(1, [NSString stringWithFormat:@"%@ is not a 3D preset (not a dictionary).", url.lastPathComponent]);
        return nil;
    }
    BKPreset *preset = [self presetWithDictionary:plist error:error];
    if (preset && preset.name.length == 0)
        preset.name = url.URLByDeletingPathExtension.lastPathComponent;
    return preset;
}

// Turns a preset dictionary into a BKPreset, resolving names exactly like
// -[VRController applyPreset:] does and falling back the way Horos falls back.
- (BKPreset *)presetWithDictionary:(NSDictionary *)dict error:(NSError **)error
{
    if (![dict isKindOfClass:[NSDictionary class]]) {
        if (error) *error = BKPresetError(1, @"A 3D preset must be a dictionary.");
        return nil;
    }
    BKPreset *preset = [[BKPreset alloc] init];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];

    if ([dict[@"name"] isKindOfClass:[NSString class]]) preset.name = dict[@"name"];
    if ([dict[@"groupName"] isKindOfClass:[NSString class]]) preset.groupName = dict[@"groupName"];
    NSString *clutName = [dict[@"CLUT"] isKindOfClass:[NSString class]] ? dict[@"CLUT"] : nil;
    NSString *opacityName = [dict[@"opacity"] isKindOfClass:[NSString class]] ? dict[@"opacity"] : nil;
    preset.clutName = clutName;
    preset.opacityName = opacityName;
    preset.usesAdvancedCLUT = [dict[@"advancedCLUT"] boolValue];

    float v;
    if (BKReadFloat(dict[@"wl"], &v)) preset.windowCenter = v;
    if (BKReadFloat(dict[@"ww"], &v)) preset.windowWidth = v;

    if (preset.usesAdvancedCLUT) {
        // "16-bit CLUT" = curves embedded in the preset; any other name = a saved
        // 16-bit CLUT file ("curves"/"colors") in the CLUT folders.
        NSArray *curves = nil;
        if (clutName && ![clutName isEqualToString:BK16BitCLUTName]) {
            NSDictionary *file = [self clutDictionaryNamed:clutName];
            if (file) curves = BKParseCurves(file[@"curves"], file[@"colors"], warnings);
            else [warnings addObject:[NSString stringWithFormat:@"16-bit CLUT \"%@\" not found; using the curves stored in the preset.", clutName]];
        }
        if (curves.count == 0)
            curves = BKParseCurves(dict[@"16bitClutCurves"], dict[@"16bitClutColors"], warnings);
        if (curves.count == 0) {
            if (error) *error = BKPresetError(2, [NSString stringWithFormat:@"Preset \"%@\" is an advanced (16-bit) preset but has no curves.", preset.name]);
            return nil;
        }
        preset.advancedCurves = curves;
        // Horos sets WL/WW from the first curve's first and last points.
        BKPresetCurve *first = curves.firstObject;
        float x0 = [first pointAtIndex:0].value, x1 = [first pointAtIndex:first.pointCount - 1].value;
        preset.windowCenter = (x0 + x1) / 2.0f;
        preset.windowWidth = x1 - x0;
    } else {
        // Colour table: unknown names fall back to "No CLUT", like -[VRController ApplyCLUTString:].
        if (clutName.length && ![clutName isEqualToString:BKNoCLUTName]) {
            NSData *r, *g, *b;
            if ([self getCLUTNamed:clutName red:&r green:&g blue:&b]) {
                preset.clutRed = r; preset.clutGreen = g; preset.clutBlue = b;
            } else {
                [warnings addObject:[NSString stringWithFormat:@"Colour table \"%@\" not found; using No CLUT (gray).", clutName]];
            }
        }
        // Opacity table: "Linear Table" means none; unknown names also fall back to linear.
        if (opacityName.length && ![opacityName isEqualToString:BKLinearOpacityName]) {
            NSArray *strings = _opacityTables[opacityName][@"Points"];
            if ([strings isKindOfClass:[NSArray class]]) {
                NSMutableData *points = [NSMutableData data];
                for (id s in strings) {
                    CGPoint pt;
                    if ([s isKindOfClass:[NSString class]] && [[self class] parsePointString:s point:&pt]) {
                        pt.x -= 1000; // Horos stores x with a +1000 offset
                        [points appendBytes:&pt length:sizeof(pt)];
                    }
                }
                preset.opacityPoints = points;
            } else {
                [warnings addObject:[NSString stringWithFormat:@"Opacity table \"%@\" not found; using Linear Table.", opacityName]];
            }
        }
    }

    // Lighting: VRController only applies the named shading when useShading is on.
    preset.shadingEnabled = [dict[@"useShading"] boolValue];
    NSString *shadingName = [dict[@"shading"] isKindOfClass:[NSString class]] ? dict[@"shading"] : nil;
    if (shadingName) {
        preset.shadingName = shadingName;
        NSDictionary *shading = nil;
        for (NSDictionary *d in _shadingPresets)
            if ([d[@"name"] isEqual:shadingName]) { shading = d; break; }
        if (shading) {
            if (BKReadFloat(shading[@"ambient"], &v)) preset.ambient = v;
            if (BKReadFloat(shading[@"diffuse"], &v)) preset.diffuse = v;
            if (BKReadFloat(shading[@"specular"], &v)) preset.specular = v;
            if (BKReadFloat(shading[@"specularPower"], &v)) preset.specularPower = v;
        } else if (preset.shadingEnabled) {
            [warnings addObject:[NSString stringWithFormat:@"Lighting \"%@\" not found; using Default.", shadingName]];
        }
    }

    if (BKReadFloat(dict[@"projection"], &v)) preset.horosProjectionMode = (int)v;
    if (BKReadFloat(dict[@"backgroundColorRedComponent"], &v)) preset.backgroundRed = v;
    if (BKReadFloat(dict[@"backgroundColorGreenComponent"], &v)) preset.backgroundGreen = v;
    if (BKReadFloat(dict[@"backgroundColorBlueComponent"], &v)) preset.backgroundBlue = v;

    NSMutableArray *filters = [NSMutableArray array];
    if ([dict[@"convolutionFilters"] isKindOfClass:[NSArray class]])
        for (id f in dict[@"convolutionFilters"])
            if ([f isKindOfClass:[NSString class]]) [filters addObject:f];
    preset.convolutionFilterNames = filters;
    preset.warnings = warnings;
    return preset;
}

- (NSArray<BKPreset *> *)presetsInDirectoryAtURL:(NSURL *)directory
                                        failures:(NSDictionary<NSString *, NSError *> **)failures
{
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                           includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    NSMutableArray *presets = [NSMutableArray array];
    NSMutableDictionary *failed = [NSMutableDictionary dictionary];
    for (NSURL *url in files) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
        NSError *err = nil;
        BKPreset *preset = [self presetWithContentsOfURL:url error:&err];
        if (preset) [presets addObject:preset];
        else failed[url.lastPathComponent] = err ?: BKPresetError(1, @"Unreadable preset.");
    }
    if (failures) *failures = failed;
    return presets;
}

@end
