// BorosKitDICOM: BKZipArchive - see BKZipArchive.h. ARC.
//
// Original BorosKit code written for this project; contains no third-party code.

#import "BKZipArchive.h"
#import "BKZipCore.h"
#import "BKDicomFile.h"   // BKDicomErrorDomain

#import <compression.h>

static NSError *BKZipError(NSString *text)
{
    return [NSError errorWithDomain:BKDicomErrorDomain code:BKDicomErrorCodeDamaged userInfo:@{NSLocalizedDescriptionKey: text}];
}

@implementation BKZipArchive

+ (NSArray<NSURL *> *)extractArchiveAtURL:(NSURL *)archiveURL toDirectory:(NSURL *)directory error:(NSError **)error
{
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) { if (error) *error = BKZipError(readError.localizedDescription ?: @"The archive could not be read."); return nil; }
    return [self extractArchiveData:data toDirectory:directory error:error];
}

// What: writes one entry to `url`, inflating when needed, and checks size + CRC. Returns NO with a reason.
+ (BOOL)writeEntry:(const BKZipEntry *)entry from:(const uint8_t *)bytes to:(NSURL *)url reason:(NSString **)reason
{
    if (![[NSFileManager defaultManager] createFileAtPath:url.path contents:nil attributes:nil]) { *reason = @"A file could not be created."; return NO; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
    if (!handle) { *reason = @"A file could not be written."; return NO; }
    const uint8_t *src = bytes + entry->dataOffset;
    uint32_t crc = 0;
    uint64_t written = 0;
    BOOL ok = YES;
    if (entry->method == 0) {
        if (entry->compressedSize != entry->uncompressedSize) { *reason = @"A stored file has inconsistent sizes."; ok = NO; }
        else {
            const uint64_t chunk = 1 << 22;
            for (uint64_t at = 0; at < entry->compressedSize && ok; at += chunk) {
                NSUInteger n = (NSUInteger)MIN(chunk, entry->compressedSize - at);
                crc = BKZipCRC32(crc, src + at, n);
                ok = [handle writeData:[NSData dataWithBytesNoCopy:(void *)(src + at) length:n freeWhenDone:NO] error:nil];
                written += n;
            }
        }
    } else {
        compression_stream stream;
        if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) { *reason = @"The decompressor could not start."; [handle closeFile]; return NO; }
        static const size_t kOut = 1 << 20;
        uint8_t *buffer = malloc(kOut);
        stream.src_ptr = src;
        stream.src_size = (size_t)entry->compressedSize;
        compression_status status = COMPRESSION_STATUS_OK;
        while (ok && buffer) {
            stream.dst_ptr = buffer;
            stream.dst_size = kOut;
            status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
            if (status == COMPRESSION_STATUS_ERROR) { ok = NO; *reason = @"A file inside the archive is damaged (cannot be unpacked)."; break; }
            size_t produced = kOut - stream.dst_size;
            if (produced) {
                crc = BKZipCRC32(crc, buffer, produced);
                ok = [handle writeData:[NSData dataWithBytesNoCopy:buffer length:produced freeWhenDone:NO] error:nil];
                written += produced;
                if (written > entry->uncompressedSize) { ok = NO; *reason = @"A file inside the archive is larger than its table entry says."; }
            }
            if (status == COMPRESSION_STATUS_END) break;
            if (produced == 0 && stream.src_size == 0) { ok = NO; *reason = @"A file inside the archive is cut short."; }
        }
        if (!buffer) { ok = NO; *reason = @"Out of memory."; }
        free(buffer);
        compression_stream_destroy(&stream);
    }
    [handle closeFile];
    if (ok && written != entry->uncompressedSize) { ok = NO; *reason = @"A file inside the archive has the wrong size."; }
    if (ok && crc != entry->crc32) { ok = NO; *reason = @"A file inside the archive is damaged (checksum mismatch)."; }
    if (!ok) [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil] ?: [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    return ok;
}

+ (NSArray<NSURL *> *)extractArchiveData:(NSData *)data toDirectory:(NSURL *)directory error:(NSError **)error
{
    BKZipEntry *entries = NULL;
    uint32_t count = 0;
    char message[256] = { 0 };
    if (!BKZipReadEntries(data.bytes, data.length, &entries, &count, message)) {
        if (error) *error = BKZipError([NSString stringWithUTF8String:message] ?: @"Damaged archive.");
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSURL *> *written = [NSMutableArray array];
    NSString *failure = nil;
    for (uint32_t i = 0; i < count && !failure; i++) {
        BKZipEntry *e = &entries[i];
        if (e->isDirectory) continue;
        char safe[1024];
        if (!BKZipSafeRelativePath(e->name, safe, sizeof(safe))) continue;   // unsafe or clutter: skipped
        if (e->encrypted) { failure = @"The archive is password-protected; unzip it first."; break; }
        if (e->method != 0 && e->method != 8) { failure = [NSString stringWithFormat:@"The archive uses an unsupported packing method (%d).", e->method]; break; }
        NSString *relative = [NSString stringWithUTF8String:safe] ?: [[NSString alloc] initWithCString:safe encoding:NSISOLatin1StringEncoding];
        NSURL *target = [directory URLByAppendingPathComponent:relative isDirectory:NO];
        // Belt and braces: the standardised target must still be inside the folder.
        if (![target.URLByStandardizingPath.path hasPrefix:directory.URLByStandardizingPath.path]) continue;
        [fm createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm fileExistsAtPath:target.path]) [fm removeItemAtURL:target error:nil];   // replaced by the new copy
        NSString *reason = nil;
        if ([self writeEntry:e from:data.bytes to:target reason:&reason]) [written addObject:target];
        else failure = reason;
    }
    BKZipFreeEntries(entries, count);
    if (failure) { if (error) *error = BKZipError(failure); return nil; }
    return written;
}

@end
