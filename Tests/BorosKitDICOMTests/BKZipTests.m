// BorosKitDICOMTests: BKZipCore / BKZipArchive on archives built here byte by byte (stored, deflated, Zip64
// fields, unsafe names, damage).
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <compression.h>
#import "BKZipCore.h"
#import "BKZipArchive.h"

@interface BKZipTests : XCTestCase
@end

typedef struct { NSString *name; NSData *content; BOOL deflate; BOOL zip64; BOOL corruptCRC; } BKZipItem;

static void P16(NSMutableData *d, uint32_t v) { uint8_t b[2] = { v, v >> 8 }; [d appendBytes:b length:2]; }
static void P32(NSMutableData *d, uint32_t v) { uint8_t b[4] = { v, v >> 8, v >> 16, v >> 24 }; [d appendBytes:b length:4]; }
static void P64(NSMutableData *d, uint64_t v) { P32(d, (uint32_t)v); P32(d, (uint32_t)(v >> 32)); }

// What: a ZIP archive in the standard layout: local headers + data, central directory, end record.
static NSData *BKMakeZip(const BKZipItem *items, int count)
{
    NSMutableData *zip = [NSMutableData data], *central = [NSMutableData data];
    for (int i = 0; i < count; i++) {
        BKZipItem it = items[i];
        NSData *packed = it.content;
        if (it.deflate) {
            size_t cap = it.content.length + 1024;
            uint8_t *buf = malloc(cap);
            size_t n = compression_encode_buffer(buf, cap, it.content.bytes, it.content.length, NULL, COMPRESSION_ZLIB);
            packed = [NSData dataWithBytesNoCopy:buf length:n freeWhenDone:YES];
        }
        uint32_t crc = BKZipCRC32(0, it.content.bytes, it.content.length) ^ (it.corruptCRC ? 1 : 0);
        NSData *name = [it.name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t offset = (uint32_t)zip.length;
        P32(zip, 0x04034b50); P16(zip, 20); P16(zip, 0x0800); P16(zip, it.deflate ? 8 : 0); P16(zip, 0); P16(zip, 0);
        P32(zip, crc); P32(zip, (uint32_t)packed.length); P32(zip, (uint32_t)it.content.length);
        P16(zip, (uint32_t)name.length); P16(zip, 0);
        [zip appendData:name];
        [zip appendData:packed];
        NSMutableData *extra = [NSMutableData data];
        if (it.zip64) { P16(extra, 1); P16(extra, 24); P64(extra, it.content.length); P64(extra, packed.length); P64(extra, offset); }
        P32(central, 0x02014b50); P16(central, 0x031E); P16(central, 45); P16(central, 0x0800); P16(central, it.deflate ? 8 : 0);
        P16(central, 0); P16(central, 0); P32(central, crc);
        P32(central, it.zip64 ? 0xFFFFFFFFu : (uint32_t)packed.length);
        P32(central, it.zip64 ? 0xFFFFFFFFu : (uint32_t)it.content.length);
        P16(central, (uint32_t)name.length); P16(central, (uint32_t)extra.length); P16(central, 0); P16(central, 0); P16(central, 0); P32(central, 0);
        P32(central, it.zip64 ? 0xFFFFFFFFu : offset);
        [central appendData:name];
        [central appendData:extra];
    }
    uint32_t cdOffset = (uint32_t)zip.length;
    [zip appendData:central];
    P32(zip, 0x06054b50); P16(zip, 0); P16(zip, 0); P16(zip, count); P16(zip, count);
    P32(zip, (uint32_t)central.length); P32(zip, cdOffset); P16(zip, 0);
    return zip;
}

@implementation BKZipTests

- (NSURL *)scratch
{
    NSURL *u = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
    return u;
}

- (void)testExtractStoredDeflatedAndZip64
{
    NSMutableData *big = [NSMutableData data];
    for (int i = 0; i < 200000; i++) { uint8_t b = (uint8_t)((i * 31) ^ (i >> 7)); [big appendBytes:&b length:1]; }
    BKZipItem items[] = {
        { @"Patient/CBCT/IM0001.dcm", [@"stored bytes" dataUsingEncoding:NSUTF8StringEncoding], NO, NO, NO },
        { @"Patient/CBCT/IM0002.dcm", big, YES, NO, NO },
        { @"manifest.json", [@"{\"format\":\"boros-dicom-package\"}" dataUsingEncoding:NSUTF8StringEncoding], YES, YES, NO },
        { @"Patient/", [NSData data], NO, NO, NO },
        { @"__MACOSX/Patient/._IM0001.dcm", [@"junk" dataUsingEncoding:NSUTF8StringEncoding], NO, NO, NO },
        { @"../escape.dcm", [@"evil" dataUsingEncoding:NSUTF8StringEncoding], NO, NO, NO },
    };
    NSData *zip = BKMakeZip(items, 6);
    BKZipEntry *entries; uint32_t count; char msg[256];
    XCTAssertTrue(BKZipReadEntries(zip.bytes, zip.length, &entries, &count, msg), @"%s", msg);
    XCTAssertEqual(count, 6u);
    XCTAssertEqual(entries[2].uncompressedSize, items[2].content.length);   // from the Zip64 extra field
    XCTAssertTrue(entries[3].isDirectory);
    BKZipFreeEntries(entries, count);

    NSURL *dir = [self scratch];
    NSError *error = nil;
    NSArray<NSURL *> *files = [BKZipArchive extractArchiveData:zip toDirectory:dir error:&error];
    XCTAssertNotNil(files, @"%@", error);
    XCTAssertEqual(files.count, 3u);   // clutter and the escaping name skipped
    NSData *back = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"Patient/CBCT/IM0002.dcm"]];
    XCTAssertEqualObjects(back, big);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[dir.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"escape.dcm"].path]);
}

- (void)testDamageIsReported
{
    BKZipItem bad[] = { { @"a.dcm", [@"hello hello hello" dataUsingEncoding:NSUTF8StringEncoding], YES, NO, YES } };
    NSError *error = nil;
    XCTAssertNil([BKZipArchive extractArchiveData:BKMakeZip(bad, 1) toDirectory:[self scratch] error:&error]);
    XCTAssertTrue([error.localizedDescription containsString:@"checksum"], @"%@", error);
    BKZipItem good[] = { { @"a.dcm", [@"hello" dataUsingEncoding:NSUTF8StringEncoding], NO, NO, NO } };
    NSData *zip = BKMakeZip(good, 1);
    XCTAssertNil([BKZipArchive extractArchiveData:[zip subdataWithRange:NSMakeRange(10, zip.length - 10)] toDirectory:[self scratch] error:&error]);
    XCTAssertNil([BKZipArchive extractArchiveData:[@"not a zip at all, sorry" dataUsingEncoding:NSUTF8StringEncoding] toDirectory:[self scratch] error:&error]);
}

- (void)testSafePathsAndCRC
{
    char out[256];
    XCTAssertTrue(BKZipSafeRelativePath("a\\b/./c.dcm", out, sizeof(out))); XCTAssertEqual(strcmp(out, "a/b/c.dcm"), 0);
    XCTAssertFalse(BKZipSafeRelativePath("/etc/passwd", out, sizeof(out)));
    XCTAssertFalse(BKZipSafeRelativePath("a/../../b", out, sizeof(out)));
    XCTAssertFalse(BKZipSafeRelativePath("C:\\x", out, sizeof(out)));
    XCTAssertFalse(BKZipSafeRelativePath("x/.DS_Store", out, sizeof(out)));
    XCTAssertEqual(BKZipCRC32(0, (const uint8_t *)"123456789", 9), 0xCBF43926u);   // the standard check value
}

@end
