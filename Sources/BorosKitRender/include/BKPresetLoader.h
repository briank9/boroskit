// BorosKitRender: BKPresetLoader
//
// What it is: reads Horos/Boros 3D preset files ("3DPRESETS/*.plist") and turns them
// into BKPreset objects the Metal renderer can use.
//
// Why it is a separate object: a preset file only NAMES its colour table, opacity
// table and lighting ("CLUT" = "VR Bones", "opacity" = "Smooth Table",
// "shading" = "Glossy Bone"). Horos looks those names up in:
//   - colour tables: the user's "Horos Data/CLUTs" folder, then the app's built-in
//     "CLUTs" folder (files "<name>.plist" with Red/Green/Blue arrays, or, for advanced
//     16-bit CLUTs, "curves"/"colors");
//   - opacity tables: the "OPACITY" user default (built-in: Logarithmic, Logarithmic
//     Inverse, Smooth; "Linear Table" means no table);
//   - lighting: the "shadingsPresets" user default (built-in: Default, Glossy
//     Vascular, Glossy Bone, Endoscopy).
// The loader knows the built-in tables (generated exactly like DefaultsOsiriX.m) and
// can be given the CLUT folders and the user's own tables, so it resolves names the
// same way the Mac app does — without AppKit, so it also works on iPad.
//
// Formats NOT readable without AppKit: none of the current Horos preset formats need
// AppKit (colours are stored as plain red/green/blue numbers). Very old OsiriX
// presets that stored NSColor archives are not supported.

#import <Foundation/Foundation.h>

@class BKPreset;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BKPresetErrorDomain;

@interface BKPresetLoader : NSObject

// Folders searched (in order) for "<name>.plist" colour tables. Put the user's
// "Horos Data/CLUTs" (or "Boros 6 Data/CLUTs") first and the app's built-in CLUTs
// folder last, like Horos does.
@property (nonatomic, copy) NSArray<NSURL *> *clutDirectories;

// Opacity tables by name, in the "OPACITY" user-default format:
// name -> @{ @"Points": @[ @"{1000, 0}", @"{1001, 0.004}", ... ] }.
// Starts with Horos' built-in tables; add the user's own with -addOpacityTables:.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSDictionary *> *opacityTables;

// Lighting presets in the "shadingsPresets" user-default format:
// @[ @{ @"name": @"Default", @"ambient": @"0.15", @"diffuse": @"0.9", ... }, ... ].
// Starts with Horos' built-in ones; add the user's own with -addShadingPresets:.
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *shadingPresets;

// A loader with Horos' built-in opacity tables and lighting and no CLUT folders.
- (instancetype)init;

// Adds / replaces opacity tables (e.g. [[NSUserDefaults standardUserDefaults]
// dictionaryForKey:@"OPACITY"] on the Mac).
- (void)addOpacityTables:(NSDictionary<NSString *, NSDictionary *> *)tables;

// Adds / replaces lighting presets by name (e.g. the "shadingsPresets" user default).
- (void)addShadingPresets:(NSArray<NSDictionary *> *)presets;

// Reads one preset file (an XML or binary plist).
- (nullable BKPreset *)presetWithContentsOfURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

// Builds a preset from an already-read preset dictionary.
- (nullable BKPreset *)presetWithDictionary:(NSDictionary *)dictionary error:(NSError * _Nullable * _Nullable)error;

// Reads every "*.plist" preset in a folder (e.g. the app's 3DPRESETS or the user's
// "Horos Data/3DPRESETS"), sorted by name. Files that fail are skipped and reported
// in `failures` (file name -> error), if given.
- (NSArray<BKPreset *> *)presetsInDirectoryAtURL:(NSURL *)directory
                                        failures:(NSDictionary<NSString *, NSError *> * _Nullable * _Nullable)failures;

// Looks up a simple 256-entry colour table by name in clutDirectories. Returns NO if
// it isn't found or isn't a 256-entry Red/Green/Blue table. "No CLUT" returns NO.
- (BOOL)getCLUTNamed:(NSString *)name
                 red:(NSData * _Nullable * _Nonnull)red
               green:(NSData * _Nullable * _Nonnull)green
                blue:(NSData * _Nullable * _Nonnull)blue;

// Parses Horos' NSStringFromPoint text, e.g. "{1000, 0.5}", without AppKit.
// Returns NO for text that is not a point.
+ (BOOL)parsePointString:(NSString *)string point:(CGPoint *)point;

@end

NS_ASSUME_NONNULL_END
