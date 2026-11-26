// BorosKitDICOM: BKZipArchive - unpacks a ZIP archive (a zipped DICOM folder, or a Boros 6 ".borosdicom"
// package) into a folder, safely.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Thin Apple glue over the plain-C BKZipCore (table of contents, safe names, CRC-32). Apple-specific here:
//   memory-mapping the archive, writing files (Foundation) and inflating DEFLATE entries with Apple's
//   Compression framework (COMPRESSION_ZLIB = raw DEFLATE, streamed so big entries never sit in memory).
//
// Plain language: every file of the archive is written below the target folder; names that would escape it
// ("../", absolute paths) and Mac clutter (__MACOSX, ._files, .DS_Store) are skipped; each file's checksum is
// verified, so a damaged download is reported instead of being shown.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BKZipArchive : NSObject

// What: extracts the archive at `archiveURL` into `directory` (created if needed). Returns the URLs of the
// files written (no folders), or nil + error (nothing usable written) when the archive is damaged, encrypted
// or uses an unsupported packing method. Existing files with the same name are replaced.
+ (nullable NSArray<NSURL *> *)extractArchiveAtURL:(NSURL *)archiveURL
                                       toDirectory:(NSURL *)directory
                                             error:(NSError * _Nullable * _Nullable)error;

// Same, from bytes in memory.
+ (nullable NSArray<NSURL *> *)extractArchiveData:(NSData *)data
                                      toDirectory:(NSURL *)directory
                                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
