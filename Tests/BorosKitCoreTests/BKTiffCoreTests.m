// Tests for BKTiffCore (TIFF reading without VTK's bundled libtiff).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// Reference: files WRITTEN BY APPLE'S ImageIO (an independent TIFF writer: uncompressed, LZW, PackBits, Deflate;
// 8 / 16-bit grey, 32-bit float grey, RGB, several pages) and small files built byte by byte in the test from the
// TIFF 6.0 specification (big-endian, BigTIFF, planar RGB, tiles, private tags, a page loop). Every decoded sample
// must equal the value that was written.

#import <XCTest/XCTest.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <compression.h>
#include "BKTiffCore.h"

@interface BKTiffCoreTests : XCTestCase
@end

// Inflate through Apple's libcompression (what the Boros glue does): skip the 2-byte zlib header.
static long BKTestInflate(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen, void *user)
{
    (void)user;
    if (srcLen < 2) return -1;
    size_t n = compression_decode_buffer(dst, dstLen, src + 2, srcLen - 2, NULL, COMPRESSION_ZLIB);
    return n == 0 ? -1 : (long)n;
}

// A grey / RGB picture with known samples, written by ImageIO as TIFF with the given compression.
static NSData *BKTestImageIOTiff(int width, int height, int bits, int channels, BOOL isFloat, int compression,
                                 int pages, NSMutableData *expected)
{
    NSMutableData *file = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)file, CFSTR("public.tiff"), pages, NULL);
    for (int p = 0; p < pages; p++)
    {
        size_t rowBytes = (size_t)width * channels * bits / 8;
        NSMutableData *px = [NSMutableData dataWithLength:rowBytes * height];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
                for (int c = 0; c < channels; c++)
                {
                    size_t i = ((size_t)y * width + x) * channels + c;
                    double v = (x * 7 + y * 13 + c * 50 + p * 31) % 251;
                    if (bits == 8) ((uint8_t *)px.mutableBytes)[i] = (uint8_t)v;
                    else if (bits == 16) ((uint16_t *)px.mutableBytes)[i] = (uint16_t)(v * 257 + x);
                    else ((float *)px.mutableBytes)[i] = (float)(v / 7.0 - 3.5);
                }
        if (expected) [expected appendData:px];
        CGColorSpaceRef cs = channels == 1 ? CGColorSpaceCreateWithName(kCGColorSpaceLinearGray) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaNone;
        if (bits == 16) info |= kCGBitmapByteOrder16Little;
        if (isFloat) info |= kCGBitmapFloatComponents | kCGBitmapByteOrder32Little;
        CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
        CGImageRef img = CGImageCreate(width, height, bits, bits * channels, rowBytes, cs, info, prov, NULL, false, kCGRenderingIntentDefault);
        NSDictionary *props = @{ (__bridge NSString *)kCGImagePropertyTIFFDictionary:
                                     @{ (__bridge NSString *)kCGImagePropertyTIFFCompression: @(compression) } };
        CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)props);
        CGImageRelease(img); CGDataProviderRelease(prov); CGColorSpaceRelease(cs);
    }
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? file : nil;
}

// --- a tiny TIFF writer for hand-made files (test only) ------------------------------------------------------
typedef struct { uint16_t tag, type; uint32_t count; uint32_t value; } BKTestEntry;

static void BKTestPut(NSMutableData *d, uint64_t v, int bytes, BOOL big)
{
    uint8_t b[8];
    for (int i = 0; i < bytes; i++) b[big ? bytes - 1 - i : i] = (uint8_t)(v >> (8 * i));
    [d appendBytes:b length:bytes];
}

// Writes one directory at the end of d (entries must be sorted; values <= 4 bytes inline); returns its offset.
static uint32_t BKTestDir(NSMutableData *d, const BKTestEntry *e, int n, uint32_t next, BOOL big)
{
    if (d.length & 1) [d appendBytes:"\0" length:1];
    uint32_t off = (uint32_t)d.length;
    BKTestPut(d, n, 2, big);
    for (int i = 0; i < n; i++)
    {
        BKTestPut(d, e[i].tag, 2, big); BKTestPut(d, e[i].type, 2, big); BKTestPut(d, e[i].count, 4, big);
        if (e[i].type == 3 && e[i].count == 1) { BKTestPut(d, e[i].value, 2, big); BKTestPut(d, 0, 2, big); }
        else BKTestPut(d, e[i].value, 4, big);
    }
    BKTestPut(d, next, 4, big);
    return off;
}

static void BKTestPatch(NSMutableData *d, size_t at, uint32_t v, BOOL big)
{
    uint8_t *p = (uint8_t *)d.mutableBytes + at;
    for (int i = 0; i < 4; i++) p[big ? 3 - i : i] = (uint8_t)(v >> (8 * i));
}

@implementation BKTiffCoreTests

- (void)checkImageIOBits:(int)bits channels:(int)channels isFloat:(BOOL)isFloat compression:(int)compression pages:(int)pages
{
    NSMutableData *expected = [NSMutableData data];
    int w = 37, h = 23;
    NSData *file = BKTestImageIOTiff(w, h, bits, channels, isFloat, compression, pages, expected);
    XCTAssertNotNil(file);
    BKTiff tif;
    XCTAssertEqual(BKTiffOpen(file.bytes, file.length, &tif), BK_TIFF_OK);
    XCTAssertEqual(tif.pageCount, pages);
    size_t pageBytes = (size_t)w * h * channels * bits / 8;
    for (int p = 0; p < pages; p++)
    {
        BKTiffPage info;
        XCTAssertEqual(BKTiffGetPage(&tif, p, &info), BK_TIFF_OK);
        XCTAssertEqual(info.width, (uint32_t)w);
        XCTAssertEqual(info.height, (uint32_t)h);
        XCTAssertEqual(info.bitsPerSample, (uint32_t)bits);
        XCTAssertEqual(info.samplesPerPixel, (uint32_t)channels);
        XCTAssertEqual(info.sampleFormat, isFloat ? (uint32_t)BK_TIFF_SAMPLE_FLOAT : (uint32_t)BK_TIFF_SAMPLE_UINT);
        XCTAssertEqual(BKTiffPageBytes(&info), pageBytes);
        NSMutableData *got = [NSMutableData dataWithLength:pageBytes];
        int r = BKTiffReadPage(&tif, p, got.mutableBytes, got.length, BKTestInflate, NULL);
        XCTAssertEqual(r, BK_TIFF_OK, @"bits %d ch %d comp %d (file compression %u, predictor %u)", bits, channels, compression, info.compression, info.predictor);
        XCTAssertEqualObjects(got, [expected subdataWithRange:NSMakeRange(p * pageBytes, pageBytes)],
                              @"bits %d ch %d float %d comp %d page %d (file: compression %u predictor %u)", bits, channels, isFloat, compression, p, info.compression, info.predictor);
    }
    BKTiffClose(&tif);
}

- (void)testImageIOFiles
{
    const int comps[4] = { 1, 5, 32773, 8 };
    for (int c = 0; c < 4; c++)
    {
        [self checkImageIOBits:8 channels:1 isFloat:NO compression:comps[c] pages:1];
        [self checkImageIOBits:16 channels:1 isFloat:NO compression:comps[c] pages:3];
        [self checkImageIOBits:8 channels:3 isFloat:NO compression:comps[c] pages:2];
        [self checkImageIOBits:32 channels:1 isFloat:YES compression:comps[c] pages:2];
    }
}

- (void)testHandMadeBigEndianPlanarAndPrivateTag
{
    // Big-endian, 16-bit RGB stored plane after plane, rows per strip 2 (3 strips per plane), plus a private
    // FluoView-style tag (34361, BYTE x 6) and a description; a second page 8-bit grey; the second page links back
    // to the first (a loop) - must still list 2 pages.
    BOOL big = YES;
    int w = 3, h = 5;
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"MM" length:2]; BKTestPut(d, 42, 2, big); BKTestPut(d, 0, 4, big);
    // Pixel planes.
    uint32_t stripOff[9], stripLen[9];
    for (int pl = 0; pl < 3; pl++)
        for (int s = 0; s < 3; s++)
        {
            int rows = s < 2 ? 2 : 1;
            stripOff[pl * 3 + s] = (uint32_t)d.length; stripLen[pl * 3 + s] = (uint32_t)(rows * w * 2);
            for (int r = 0; r < rows; r++) for (int x = 0; x < w; x++) BKTestPut(d, 1000 * pl + 100 * (s * 2 + r) + x, 2, big);
        }
    uint32_t offsArr = (uint32_t)d.length; for (int i = 0; i < 9; i++) BKTestPut(d, stripOff[i], 4, big);
    uint32_t lensArr = (uint32_t)d.length; for (int i = 0; i < 9; i++) BKTestPut(d, stripLen[i], 4, big);
    uint32_t bpsArr = (uint32_t)d.length; for (int i = 0; i < 3; i++) BKTestPut(d, 16, 2, big);
    uint32_t desc = (uint32_t)d.length; [d appendBytes:"Hello\0" length:6];
    uint32_t priv = (uint32_t)d.length; [d appendBytes:"\x01\x02\x03\x04\x05\x06" length:6];
    uint32_t grey = (uint32_t)d.length; [d appendBytes:"\x0a\x0b\x0c\x0d" length:4];
    BKTestEntry e1[] = { {256, 3, 1, (uint32_t)w}, {257, 3, 1, (uint32_t)h}, {258, 3, 3, bpsArr}, {259, 3, 1, 1},
        {262, 3, 1, 2}, {270, 2, 6, desc}, {273, 4, 9, offsArr}, {277, 3, 1, 3}, {278, 3, 1, 2}, {279, 4, 9, lensArr},
        {284, 3, 1, 2}, {34361, 1, 6, priv} };
    uint32_t dir1 = BKTestDir(d, e1, 12, 0, big);
    BKTestEntry e2[] = { {256, 3, 1, 2}, {257, 3, 1, 2}, {258, 3, 1, 8}, {273, 4, 1, grey}, {279, 4, 1, 4} };
    uint32_t dir2 = BKTestDir(d, e2, 5, dir1, big);                         // loops back to page 1
    BKTestPatch(d, 4, dir1, big);
    BKTestPatch(d, dir1 + 2 + 12 * 12, dir2, big);

    BKTiff tif;
    XCTAssertEqual(BKTiffOpen(d.bytes, d.length, &tif), BK_TIFF_OK);
    XCTAssertEqual(tif.pageCount, 2);
    BKTiffPage p;
    BKTiffGetPage(&tif, 0, &p);
    XCTAssertEqual(p.planarConfig, 2u);
    XCTAssertEqual(p.rowsPerStrip, 2u);
    XCTAssertEqual(BKTiffPageBytes(&p), (size_t)(3 * w * h * 2));
    uint16_t out[45];
    XCTAssertEqual(BKTiffReadPage(&tif, 0, out, sizeof(out), NULL, NULL), BK_TIFF_OK);
    for (int pl = 0; pl < 3; pl++) for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        XCTAssertEqual(out[pl * w * h + y * w + x], 1000 * pl + 100 * y + x);
    uint16_t type; uint64_t count; const uint8_t *bytes;
    XCTAssertTrue(BKTiffFindTag(&tif, 0, 34361, &type, &count, &bytes));
    XCTAssertEqual(type, 1); XCTAssertEqual(count, 6u); XCTAssertEqual(bytes[5], 6);
    XCTAssertTrue(BKTiffFindTag(&tif, 0, BK_TIFF_TAG_IMAGE_DESCRIPTION, &type, &count, &bytes));
    XCTAssertEqual(strcmp((const char *)bytes, "Hello"), 0);
    XCTAssertFalse(BKTiffFindTag(&tif, 1, 34361, NULL, NULL, NULL));
    uint8_t g[4];
    XCTAssertEqual(BKTiffReadPage(&tif, 1, g, 4, NULL, NULL), BK_TIFF_OK);
    XCTAssertEqual(g[3], 0x0d);
    BKTiffClose(&tif);
}

- (void)testHandMadeTilesBigTiffAndPredictor
{
    // Little-endian BigTIFF, 8-bit grey 5 x 3 in 4 x 4 tiles (2 x 1 tiles, edge tile padded), horizontal predictor.
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"II" length:2]; BKTestPut(d, 43, 2, NO); BKTestPut(d, 8, 2, NO); BKTestPut(d, 0, 2, NO);
    BKTestPut(d, 0, 8, NO);
    uint8_t img[3][5] = { {10, 20, 30, 40, 50}, {5, 6, 7, 8, 9}, {200, 100, 250, 0, 1} };
    uint64_t tileOff[2];
    for (int t = 0; t < 2; t++)
    {
        tileOff[t] = d.length;
        for (int r = 0; r < 4; r++)
        {
            uint8_t row[4] = { 0 }, prev = 0;
            for (int c = 0; c < 4; c++)
            {
                int x = t * 4 + c;
                uint8_t v = (r < 3 && x < 5) ? img[r][x] : 0;
                row[c] = (uint8_t)(v - prev); prev = v;                     // predictor 2: store differences
            }
            [d appendBytes:row length:4];
        }
    }
    // BigTIFF directory: 8-byte count, 20-byte entries (tag, type, 8-byte count, 8-byte value), 8-byte next.
    uint64_t offs = d.length; BKTestPut(d, tileOff[0], 8, NO); BKTestPut(d, tileOff[1], 8, NO);
    uint64_t dir = d.length;
    struct { uint16_t tag, type; uint64_t count, value; } e[] = {
        {256, 3, 1, 5}, {257, 3, 1, 3}, {258, 3, 1, 8}, {259, 3, 1, 1}, {317, 3, 1, 2},
        {322, 3, 1, 4}, {323, 3, 1, 4}, {324, 16, 2, offs}, {325, 4, 2, 16 | (16ull << 32)} };
    int n = (int)(sizeof(e) / sizeof(e[0]));
    BKTestPut(d, n, 8, NO);
    for (int i = 0; i < n; i++) { BKTestPut(d, e[i].tag, 2, NO); BKTestPut(d, e[i].type, 2, NO); BKTestPut(d, e[i].count, 8, NO); BKTestPut(d, e[i].value, 8, NO); }
    BKTestPut(d, 0, 8, NO);
    uint8_t *bytes = (uint8_t *)d.mutableBytes;
    for (int i = 0; i < 8; i++) bytes[8 + i] = (uint8_t)(dir >> (8 * i));

    BKTiff tif;
    XCTAssertEqual(BKTiffOpen(d.bytes, d.length, &tif), BK_TIFF_OK);
    XCTAssertEqual(tif.bigTiff, 1);
    BKTiffPage p;
    BKTiffGetPage(&tif, 0, &p);
    XCTAssertEqual(p.tiled, 1u);
    uint8_t out[15];
    XCTAssertEqual(BKTiffReadPage(&tif, 0, out, sizeof(out), NULL, NULL), BK_TIFF_OK);
    for (int y = 0; y < 3; y++) for (int x = 0; x < 5; x++) XCTAssertEqual(out[y * 5 + x], img[y][x], @"(%d,%d)", x, y);
    BKTiffClose(&tif);
}

- (void)testFloatingPointPredictor
{
    // 3 x 2 float grey, little-endian, uncompressed, predictor 3 (TIFF Technical Note 3): per row the 4 bytes of
    // every sample are split into planes (most significant byte first), then each byte minus the byte before.
    const float values[2][3] = { { 1.5f, -2.25f, 1000.0f }, { 3.0e-3f, 0.0f, -7.75e5f } };
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"II" length:2]; BKTestPut(d, 42, 2, NO); BKTestPut(d, 0, 4, NO);
    uint32_t pix = (uint32_t)d.length;
    for (int y = 0; y < 2; y++)
    {
        uint8_t planes[12], diff[12];
        for (int x = 0; x < 3; x++)
        {
            uint32_t bits; memcpy(&bits, &values[y][x], 4);
            for (int b = 0; b < 4; b++) planes[b * 3 + x] = (uint8_t)(bits >> (8 * (3 - b)));
        }
        for (int i = 0; i < 12; i++) diff[i] = (uint8_t)(planes[i] - (i ? planes[i - 1] : 0));
        [d appendBytes:diff length:12];
    }
    BKTestEntry e[] = { {256, 3, 1, 3}, {257, 3, 1, 2}, {258, 3, 1, 32}, {273, 4, 1, pix}, {279, 4, 1, 24},
        {317, 3, 1, 3}, {339, 3, 1, 3} };
    uint32_t dir = BKTestDir(d, e, 7, 0, NO);
    BKTestPatch(d, 4, dir, NO);
    BKTiff tif;
    XCTAssertEqual(BKTiffOpen(d.bytes, d.length, &tif), BK_TIFF_OK);
    float out[6];
    XCTAssertEqual(BKTiffReadPage(&tif, 0, out, sizeof(out), NULL, NULL), BK_TIFF_OK);
    for (int y = 0; y < 2; y++) for (int x = 0; x < 3; x++) XCTAssertEqual(out[y * 3 + x], values[y][x]);
    BKTiffClose(&tif);
}

- (void)testCodecsAndBadInput
{
    // PackBits example from the TIFF 6.0 specification (section 9).
    const uint8_t packed[] = { 0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80, 0x00, 0x2A, 0x22, 0xF7, 0xAA };
    const uint8_t unpacked[] = { 0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0x22,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    uint8_t out[64];
    XCTAssertEqual(BKTiffUnpackBits(packed, sizeof(packed), out, sizeof(out)), (long)sizeof(unpacked));
    XCTAssertEqual(memcmp(out, unpacked, sizeof(unpacked)), 0);
    // LZW: Clear, 'A', 'B', 258 ("AB"), End -> "ABAB" (9-bit codes, most significant bit first).
    // Codes: 256 100000000, 65 001000001, 66 001000010, 258 100000010, 257 100000001.
    const uint8_t lzw[] = { 0x80, 0x10, 0x48, 0x50, 0x28, 0x08 };
    XCTAssertEqual(BKTiffDecodeLZW(lzw, sizeof(lzw), out, sizeof(out)), 4);
    XCTAssertEqual(memcmp(out, "ABAB", 4), 0);
    BKTiff tif;
    XCTAssertEqual(BKTiffOpen((const uint8_t *)"GIF89a....", 10, &tif), BK_TIFF_ERROR);
    XCTAssertEqual(BKTiffOpen((const uint8_t *)"II*\0\xff\xff\0\0", 8, &tif), BK_TIFF_ERROR);
    XCTAssertEqual(BKTiffOpen(NULL, 0, &tif), BK_TIFF_ERROR);
}

@end
