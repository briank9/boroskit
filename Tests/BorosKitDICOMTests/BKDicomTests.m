// BorosKitDICOMTests: the DICOM reader, lossless JPEG / RLE decoders and the slice sorter, on synthetic files
// generated here (no real patient data).
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <compression.h>
#import "BKTestDicomWriter.h"
#import "BKDicomCore.h"
#import "BKDicomFile.h"
#import "BKDicomVolume.h"
#import "BKDicomSeriesCore.h"
#import "BKJpegLosslessCore.h"
#import "BKRleCore.h"

static NSString *const kExplicitLE = @"1.2.840.10008.1.2.1";
static NSString *const kImplicitLE = @"1.2.840.10008.1.2";
static NSString *const kExplicitBE = @"1.2.840.10008.1.2.2";

@interface BKDicomTests : XCTestCase
@end

@implementation BKDicomTests

// A test image: a gradient with a bright square, values -1000..2000.
static void BKFillImage(int16_t *v, uint32_t rows, uint32_t cols, int seed)
{
    for (uint32_t y = 0; y < rows; y++)
        for (uint32_t x = 0; x < cols; x++) {
            int value = -1000 + (int)((x * 7 + y * 13 + seed * 31) % 1500);
            if (x > cols / 4 && x < cols / 2 && y > rows / 4 && y < rows / 2) value = 2000 - seed;
            v[y * cols + x] = (int16_t)value;
        }
}

- (void)checkSliceEncoding:(BKTestEncoding)encoding syntax:(NSString *)syntax
{
    uint32_t rows = 9, cols = 11;
    int16_t values[99];
    BKFillImage(values, rows, cols, 3);
    NSData *file = BKTestCTSlice(encoding, syntax, rows, cols, values, 12.5, 4, @"1.2.3.9");
    NSError *error = nil;
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:file error:&error];
    XCTAssertNotNil(f, @"%@", error);
    XCTAssertTrue(f.canDecode, @"%@", f.unsupportedReason);
    XCTAssertEqualObjects(f.modality, @"CT");
    XCTAssertEqualObjects(f.displayPatientName, @"Phantom, Test");
    XCTAssertEqualObjects(f.seriesInstanceUID, @"1.2.3.9");
    XCTAssertEqual(f.instanceNumber, 4);
    XCTAssertEqual(f.rows, rows);
    XCTAssertEqual(f.columns, cols);
    XCTAssertEqualWithAccuracy(f.pixelSpacingX, 0.25, 1e-12);   // between columns = PixelSpacing[1]
    XCTAssertEqualWithAccuracy(f.pixelSpacingY, 0.5, 1e-12);
    double p[3], o[6];
    XCTAssertTrue([f getPosition:p orientation:o forFrame:0]);
    XCTAssertEqualWithAccuracy(p[2], 12.5, 1e-12);
    XCTAssertEqualWithAccuracy(o[4], 1.0, 1e-12);
    float out[99];
    XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
    for (int i = 0; i < 99; i++) XCTAssertEqual(out[i], (float)values[i]);
}

- (void)testExplicitLittleEndian { [self checkSliceEncoding:BKTestEncodingExplicitLE syntax:kExplicitLE]; }
- (void)testImplicitLittleEndian { [self checkSliceEncoding:BKTestEncodingImplicitLE syntax:kImplicitLE]; }
- (void)testExplicitBigEndian { [self checkSliceEncoding:BKTestEncodingExplicitBE syntax:kExplicitBE]; }

// 12 bits stored in 16, with junk in the top 4 bits (overlay bits in old files) and signed values.
- (void)testBitsStoredMaskingAndSign
{
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingImplicitLE];
    [w us:0x0028 :0x0002 value:1];
    [w string:0x0028 :0x0004 vr:@"CS" value:@"MONOCHROME2"];
    [w us:0x0028 :0x0010 value:1];
    [w us:0x0028 :0x0011 value:4];
    [w us:0x0028 :0x0100 value:16];
    [w us:0x0028 :0x0101 value:12];
    [w us:0x0028 :0x0102 value:11];
    [w us:0x0028 :0x0103 value:1];
    uint16_t stored[4] = { 0xF000 | 0x0005, 0xA000 | 0x0FFF, 0x0800, 0x07FF };   // 5, -1, -2048, 2047
    [w pixelData:[NSData dataWithBytes:stored length:8] vr:@"OW"];
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:kImplicitLE] error:nil];
    float out[4];
    XCTAssertTrue([f decodeFrame:0 into:out error:nil]);
    XCTAssertEqual(out[0], 5); XCTAssertEqual(out[1], -1); XCTAssertEqual(out[2], -2048); XCTAssertEqual(out[3], 2047);
}

// Sequences (defined and undefined length, nested, private UN) in front of the image are stepped over.
- (void)testSequencesAreSkipped
{
    for (int enc = 0; enc < 3; enc++) {
        BKTestEncoding encoding = (BKTestEncoding)enc;
        BKTestDicomWriter *inner = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [inner string:0x0008 :0x1150 vr:@"UI" value:@"1.2.3"];
        [inner string:0x0020 :0x0032 vr:@"DS" value:@"99\\99\\99"];   // must NOT become the image position
        BKTestDicomWriter *nested = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [nested sequence:0x0008 :0x1140 items:@[inner.body, inner.body] undefinedLength:YES];
        BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [w string:0x0008 :0x0060 vr:@"CS" value:@"CT"];
        [w sequence:0x0008 :0x1115 items:@[nested.body] undefinedLength:YES];
        [w sequence:0x0008 :0x1120 items:@[inner.body] undefinedLength:NO];
        [w sequence:0x0009 :0x1010 items:@[inner.body] undefinedLength:YES];   // private
        [w string:0x0020 :0x0032 vr:@"DS" value:@"1\\2\\3"];
        [w string:0x0020 :0x0037 vr:@"DS" value:@"1\\0\\0\\0\\1\\0"];
        [w us:0x0028 :0x0010 value:1];
        [w us:0x0028 :0x0011 value:2];
        [w us:0x0028 :0x0100 value:8];
        [w us:0x0028 :0x0101 value:8];
        [w us:0x0028 :0x0102 value:7];
        uint8_t px[2] = { 10, 200 };
        [w pixelData:[NSData dataWithBytes:px length:2] vr:@"OB"];
        NSString *syntax = encoding == BKTestEncodingImplicitLE ? kImplicitLE : (encoding == BKTestEncodingExplicitLE ? kExplicitLE : kExplicitBE);
        NSError *error = nil;
        BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:syntax] error:&error];
        XCTAssertNotNil(f, @"%@", error);
        double p[3], o[6];
        XCTAssertTrue([f getPosition:p orientation:o forFrame:0]);
        XCTAssertEqualWithAccuracy(p[0], 1, 1e-12);
        XCTAssertEqualWithAccuracy(p[2], 3, 1e-12);
        float out[2];
        XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
        XCTAssertEqual(out[0], 10); XCTAssertEqual(out[1], 200);
    }
}

// Big endian files keep 8-bit pixels in OW words with the bytes of each word swapped.
- (void)testBigEndianEightBitOW
{
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitBE];
    [w us:0x0028 :0x0010 value:1];
    [w us:0x0028 :0x0011 value:4];
    [w us:0x0028 :0x0100 value:8];
    [w us:0x0028 :0x0101 value:8];
    [w us:0x0028 :0x0102 value:7];
    uint8_t px[4] = { 2, 1, 4, 3 };   // pixels 1, 2, 3, 4 as big-endian words
    [w pixelData:[NSData dataWithBytes:px length:4] vr:@"OW"];
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:kExplicitBE] error:nil];
    float out[4];
    XCTAssertTrue([f decodeFrame:0 into:out error:nil]);
    XCTAssertEqual(out[0], 1); XCTAssertEqual(out[1], 2); XCTAssertEqual(out[2], 3); XCTAssertEqual(out[3], 4);
}

// Enhanced multi-frame: geometry and rescale from the shared / per-frame functional groups.
- (NSData *)enhancedFileWithFrames:(int)frames encoding:(BKTestEncoding)encoding
{
    NSMutableArray<NSData *> *perFrame = [NSMutableArray array];
    for (int k = 0; k < frames; k++) {
        BKTestDicomWriter *pos = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [pos string:0x0020 :0x0032 vr:@"DS" value:[NSString stringWithFormat:@"0\\0\\%d", 100 - 2 * k]];   // reversed order
        BKTestDicomWriter *rescale = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [rescale string:0x0028 :0x1052 vr:@"DS" value:[NSString stringWithFormat:@"%d", -1000 - k]];
        [rescale string:0x0028 :0x1053 vr:@"DS" value:@"1"];
        BKTestDicomWriter *item = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
        [item sequence:0x0020 :0x9113 items:@[pos.body] undefinedLength:(k % 2) == 0];
        [item sequence:0x0028 :0x9145 items:@[rescale.body] undefinedLength:YES];
        [perFrame addObject:item.body];
    }
    BKTestDicomWriter *orient = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
    [orient string:0x0020 :0x0037 vr:@"DS" value:@"1\\0\\0\\0\\1\\0"];
    BKTestDicomWriter *measures = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
    [measures string:0x0028 :0x0030 vr:@"DS" value:@"0.3\\0.3"];
    [measures string:0x0018 :0x0050 vr:@"DS" value:@"0.3"];
    BKTestDicomWriter *sharedItem = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
    [sharedItem sequence:0x0020 :0x9116 items:@[orient.body] undefinedLength:NO];
    [sharedItem sequence:0x0028 :0x9110 items:@[measures.body] undefinedLength:YES];

    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
    [w string:0x0008 :0x0060 vr:@"CS" value:@"CT"];
    [w string:0x0020 :0x000E vr:@"UI" value:@"1.2.3.77"];
    [w us:0x0028 :0x0002 value:1];
    [w string:0x0028 :0x0004 vr:@"CS" value:@"MONOCHROME2"];
    [w string:0x0028 :0x0008 vr:@"IS" value:[NSString stringWithFormat:@"%d", frames]];
    [w us:0x0028 :0x0010 value:2];
    [w us:0x0028 :0x0011 value:2];
    [w us:0x0028 :0x0100 value:16];
    [w us:0x0028 :0x0101 value:16];
    [w us:0x0028 :0x0102 value:15];
    [w sequence:0x5200 :0x9229 items:@[sharedItem.body] undefinedLength:YES];
    [w sequence:0x5200 :0x9230 items:perFrame undefinedLength:YES];
    NSMutableData *px = [NSMutableData dataWithLength:frames * 4 * 2];
    uint16_t *v = px.mutableBytes;
    for (int k = 0; k < frames; k++) for (int i = 0; i < 4; i++) v[k * 4 + i] = (uint16_t)(1000 + 10 * k + i);
    if (encoding == BKTestEncodingExplicitBE) for (int i = 0; i < frames * 4; i++) v[i] = (uint16_t)((v[i] >> 8) | (v[i] << 8));
    [w pixelData:px vr:@"OW"];
    NSString *syntax = encoding == BKTestEncodingImplicitLE ? kImplicitLE : (encoding == BKTestEncodingExplicitLE ? kExplicitLE : kExplicitBE);
    return [w fileWithTransferSyntax:syntax];
}

- (void)testEnhancedMultiFrame
{
    for (int enc = 0; enc < 3; enc++) {
        NSData *file = [self enhancedFileWithFrames:5 encoding:(BKTestEncoding)enc];
        NSError *error = nil;
        BKDicomFile *f = [[BKDicomFile alloc] initWithData:file error:&error];
        XCTAssertNotNil(f, @"%@", error);
        XCTAssertEqual(f.numberOfFrames, 5u);
        XCTAssertEqualWithAccuracy(f.pixelSpacingX, 0.3, 1e-12);
        double p[3], o[6];
        XCTAssertTrue([f getPosition:p orientation:o forFrame:3]);
        XCTAssertEqualWithAccuracy(p[2], 94, 1e-12);
        float out[4];
        XCTAssertTrue([f decodeFrame:3 into:out error:&error], @"%@", error);
        XCTAssertEqual(out[1], 1000 + 30 + 1 - 1000 - 3);   // per-frame intercept -1003

        // As a volume: frames sorted by position (ascending along the normal = reversed here).
        BKDicomVolume *vol = [BKDicomVolume volumeWithFiles:@[f] maximumVoxels:0 progress:nil error:&error];
        XCTAssertNotNil(vol, @"%@", error);
        XCTAssertEqual(vol.depth, 5u);
        XCTAssertEqualWithAccuracy(vol.spacingZ, 2.0, 1e-9);
        const float *vox = vol.voxels.bytes;
        XCTAssertEqual(vox[0], 1000 + 40 - 1004);   // first sorted slice = frame 4 (z = 92)
        double m[16];
        [vol getVoxelToPatient:m];
        XCTAssertEqualWithAccuracy(m[14], 92, 1e-9);
        XCTAssertEqualWithAccuracy(m[10], 2, 1e-9);
    }
}

// ---- Lossless JPEG ------------------------------------------------------------------------------------

- (void)testJpegLosslessRoundTrip
{
    uint32_t W = 37, H = 23;
    for (uint32_t precision = 8; precision <= 16; precision += 4) {
        for (uint32_t comps = 1; comps <= 3; comps += 2) {
            size_t n = (size_t)W * H * comps;
            uint16_t *src = malloc(n * 2), *dst = malloc(n * 2);
            uint32_t seed = 12345;
            for (size_t i = 0; i < n; i++) {
                seed = seed * 1103515245u + 12345u;
                uint32_t smooth = (uint32_t)((i % (W * comps)) * 37 + (i / (W * comps)) * 101);
                src[i] = (uint16_t)((smooth + ((seed >> 16) & 63)) & ((1u << precision) - 1));
            }
            // Extremes (the "category 16" difference) in the first rows.
            src[0] = 0; if (n > comps) src[comps] = (uint16_t)((1u << precision) - 1);
            for (int predictor = 1; predictor <= 7; predictor++) {
                for (int pt = 0; pt <= 2; pt += 2) {
                    for (uint32_t restart = 0; restart <= W * 2; restart += W * 2) {
                        // The point transform drops low bits: compare with the input's high bits only.
                        NSData *jpeg = BKTestEncodeJpegLossless(src, W, H, comps, precision, predictor, pt, restart);
                        BKJpegLosslessImage image;
                        char message[256] = { 0 };
                        XCTAssertTrue(BKJpegLosslessDecode(jpeg.bytes, jpeg.length, dst, n, &image, message), @"%s", message);
                        XCTAssertEqual(image.width, W);
                        XCTAssertEqual(image.components, comps);
                        size_t bad = 0;
                        for (size_t i = 0; i < n; i++) if (dst[i] != (uint16_t)((src[i] >> pt) << pt)) bad++;
                        XCTAssertEqual(bad, 0u, @"precision %u comps %u predictor %d pt %d restart %u", precision, comps, predictor, pt, restart);
                    }
                }
            }
            free(src); free(dst);
        }
    }
}

- (void)testJpegLosslessRejectsGarbage
{
    uint8_t junk[64] = { 0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 4, 0, 4, 1, 1, 0x11, 0 };
    uint16_t out[16];
    char message[256] = { 0 };
    XCTAssertFalse(BKJpegLosslessDecode(junk, sizeof(junk), out, 16, NULL, message));
    XCTAssertTrue(strstr(message, "lossy") != NULL, @"%s", message);
    XCTAssertFalse(BKJpegLosslessDecode(junk, 3, out, 16, NULL, message));
}

// A two-frame CBCT-style series stored as JPEG Lossless SV1, with and without an offset table, and with a
// frame split over two fragments.
- (void)testEncapsulatedJpegLosslessMultiFrame
{
    uint32_t W = 16, H = 8;
    uint16_t a[128], b[128];
    for (int i = 0; i < 128; i++) { a[i] = (uint16_t)(i * 40); b[i] = (uint16_t)(5000 - i * 7); }
    NSData *ja = BKTestEncodeJpegLossless(a, W, H, 1, 16, 1, 0, 0), *jb = BKTestEncodeJpegLossless(b, W, H, 1, 16, 1, 0, 0);
    for (int variant = 0; variant < 3; variant++) {
        BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
        [w string:0x0028 :0x0004 vr:@"CS" value:@"MONOCHROME2"];
        [w string:0x0028 :0x0008 vr:@"IS" value:@"2"];
        [w us:0x0028 :0x0010 value:H];
        [w us:0x0028 :0x0011 value:W];
        [w us:0x0028 :0x0100 value:16];
        [w us:0x0028 :0x0101 value:16];
        [w us:0x0028 :0x0102 value:15];
        [w string:0x0028 :0x1052 vr:@"DS" value:@"-1000"];
        NSArray *fragments; NSArray *table = nil;
        NSUInteger padA = ja.length + (ja.length & 1);
        if (variant == 0) { fragments = @[ja, jb]; table = @[@0, @(8 + padA)]; }
        else if (variant == 1) { fragments = @[ja, jb]; }
        else {
            NSUInteger cut = 20;   // even
            fragments = @[[ja subdataWithRange:NSMakeRange(0, cut)], [ja subdataWithRange:NSMakeRange(cut, ja.length - cut)], jb];
        }
        [w encapsulatedPixelData:fragments offsetTable:table];
        NSError *error = nil;
        BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:@"1.2.840.10008.1.2.4.70"] error:&error];
        XCTAssertNotNil(f, @"%@", error);
        XCTAssertTrue(f.canDecode, @"%@", f.unsupportedReason);
        XCTAssertEqualObjects(f.transferSyntaxName, @"JPEG Lossless (SV1)");
        float out[128];
        XCTAssertTrue([f decodeFrame:1 into:out error:&error], @"variant %d: %@", variant, error);
        XCTAssertEqual(out[5], (float)b[5] - 1000);
        XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"variant %d: %@", variant, error);
        XCTAssertEqual(out[127], (float)a[127] - 1000);
    }
}

// ---- RLE ------------------------------------------------------------------------------------------------

- (void)testRle16BitAndColour
{
    uint32_t W = 20, H = 6;
    // 16-bit signed grey with runs and literals.
    int16_t grey[120];
    for (int i = 0; i < 120; i++) grey[i] = (int16_t)(i < 40 ? -1000 : (i * 97) % 3000 - 500);
    NSData *rle = BKTestEncodeRle((const uint8_t *)grey, 120, 1, 2);
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    [w us:0x0028 :0x0010 value:H];
    [w us:0x0028 :0x0011 value:W];
    [w us:0x0028 :0x0100 value:16];
    [w us:0x0028 :0x0101 value:16];
    [w us:0x0028 :0x0102 value:15];
    [w us:0x0028 :0x0103 value:1];
    [w encapsulatedPixelData:@[rle] offsetTable:nil];
    NSError *error = nil;
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:@"1.2.840.10008.1.2.5"] error:&error];
    float out[120];
    XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
    for (int i = 0; i < 120; i++) XCTAssertEqual(out[i], grey[i]);

    // 8-bit RGB -> luminance.
    uint8_t rgb[360];
    for (int i = 0; i < 120; i++) { rgb[3 * i] = (uint8_t)(i * 2); rgb[3 * i + 1] = 100; rgb[3 * i + 2] = (uint8_t)(255 - i); }
    NSData *rle3 = BKTestEncodeRle(rgb, 120, 3, 1);
    BKTestDicomWriter *w3 = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    [w3 us:0x0028 :0x0002 value:3];
    [w3 string:0x0028 :0x0004 vr:@"CS" value:@"RGB"];
    [w3 us:0x0028 :0x0010 value:H];
    [w3 us:0x0028 :0x0011 value:W];
    [w3 us:0x0028 :0x0100 value:8];
    [w3 us:0x0028 :0x0101 value:8];
    [w3 us:0x0028 :0x0102 value:7];
    [w3 encapsulatedPixelData:@[rle3] offsetTable:nil];
    f = [[BKDicomFile alloc] initWithData:[w3 fileWithTransferSyntax:@"1.2.840.10008.1.2.5"] error:&error];
    XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
    XCTAssertEqualWithAccuracy(out[10], 0.299 * 20 + 0.587 * 100 + 0.114 * 245, 1e-3);
}

// ---- ImageIO-decoded syntaxes (JPEG baseline, JPEG 2000) ---------------------------------------------------

static NSData *BKEncodeWithImageIO(const uint8_t *grey, size_t W, size_t H, size_t bits, CFStringRef type, BOOL lossless)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    size_t rowBytes = W * bits / 8;
    CGBitmapInfo info = bits == 16 ? (CGBitmapInfo)kCGBitmapByteOrder16Little : 0;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, grey, rowBytes * H, NULL);
    CGImageRef image = CGImageCreate(W, H, bits, bits, rowBytes, space, info, provider, NULL, false, kCGRenderingIntentDefault);
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, type, 1, NULL);
    NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: lossless ? @1.0 : @0.95};
    BOOL ok = NO;
    if (dest) { CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props); ok = CGImageDestinationFinalize(dest); CFRelease(dest); }
    CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(space);
    return ok ? out : nil;
}

- (BKDicomFile *)fileWithFragment:(NSData *)fragment syntax:(NSString *)syntax W:(int)W H:(int)H bits:(int)bits
{
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    [w string:0x0028 :0x0004 vr:@"CS" value:@"MONOCHROME2"];
    [w us:0x0028 :0x0010 value:H];
    [w us:0x0028 :0x0011 value:W];
    [w us:0x0028 :0x0100 value:bits == 8 ? 8 : 16];
    [w us:0x0028 :0x0101 value:bits];
    [w us:0x0028 :0x0102 value:bits - 1];
    [w encapsulatedPixelData:@[fragment] offsetTable:nil];
    return [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:syntax] error:nil];
}

- (void)testJpegBaselineThroughImageIO
{
    int W = 32, H = 16;
    uint8_t grey[512];
    for (int i = 0; i < 512; i++) grey[i] = (uint8_t)(((i % W) * 8 + (i / W) * 4) & 0xFF);
    NSData *jpeg = BKEncodeWithImageIO(grey, W, H, 8, CFSTR("public.jpeg"), NO);
    XCTAssertNotNil(jpeg);
    BKDicomFile *f = [self fileWithFragment:jpeg syntax:@"1.2.840.10008.1.2.4.50" W:W H:H bits:8];
    float out[512];
    NSError *error = nil;
    XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
    double maxError = 0;
    for (int i = 0; i < 512; i++) maxError = fmax(maxError, fabs(out[i] - grey[i]));
    XCTAssertLessThan(maxError, 12.0);   // lossy, but the same picture
}

// JPEG 2000 frames in DICOM are raw codestreams: take the 'jp2c' box out of ImageIO's JP2 file. ImageIO's
// encoder writes 8-bit JPEG 2000 only, so the round trip is checked with 8-bit pixels; a 12/16-bit file whose
// decode comes back as 8 bits must be refused (never shown with lost precision).
- (void)testJpeg2000ThroughImageIO
{
    int W = 24, H = 12;
    uint8_t grey[288];
    for (int i = 0; i < 288; i++) grey[i] = (uint8_t)((i * 13 + 100) & 0xFF);
    NSData *jp2 = BKEncodeWithImageIO(grey, W, H, 8, CFSTR("public.jpeg-2000"), YES);
    if (jp2 == nil) { NSLog(@"JPEG 2000 encoding not available on this system; test skipped"); return; }
    const uint8_t *b = jp2.bytes;
    NSData *codestream = nil;
    for (NSUInteger i = 0; i + 8 <= jp2.length; i++)
        if (memcmp(b + i + 4, "jp2c", 4) == 0) {
            uint32_t len = ((uint32_t)b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
            NSUInteger end = len ? i + len : jp2.length;
            codestream = [jp2 subdataWithRange:NSMakeRange(i + 8, MIN(end, jp2.length) - i - 8)];
            break;
        }
    XCTAssertNotNil(codestream);
    for (NSData *payload in @[codestream, jp2]) {
        BKDicomFile *f = [self fileWithFragment:payload syntax:@"1.2.840.10008.1.2.4.90" W:W H:H bits:8];
        float out[288];
        NSError *error = nil;
        XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
        double maxError = 0;
        for (int i = 0; i < 288; i++) maxError = fmax(maxError, fabs(out[i] - grey[i]));
        XCTAssertLessThan(maxError, 1.0, @"lossless JPEG 2000 must round-trip exactly");
    }
    BKDicomFile *deep = [self fileWithFragment:codestream syntax:@"1.2.840.10008.1.2.4.90" W:W H:H bits:12];
    float out[288];
    NSError *error = nil;
    XCTAssertFalse([deep decodeFrame:0 into:out error:&error]);
    XCTAssertTrue([error.localizedDescription containsString:@"8 bits"], @"%@", error);
}

// ---- Deflate, unsupported and damaged files -------------------------------------------------------------

- (void)testDeflatedDataset
{
    int16_t values[6] = { -1000, 0, 50, 400, 1200, 3000 };
    NSData *plain = BKTestCTSlice(BKTestEncodingExplicitLE, @"1.2.840.10008.1.2.1.99", 2, 3, values, 0, 1, @"1.2.3");
    // Split off preamble + meta (everything up to the dataset), deflate the rest.
    BKDicomInfo info;
    char message[256];
    BKDicomParseFile(plain.bytes, plain.length, &info, message);
    size_t at = info.datasetOffset;
    BKDicomInfoFree(&info);
    NSData *dataset = [plain subdataWithRange:NSMakeRange(at, plain.length - at)];
    size_t cap = dataset.length * 2 + 1024;
    uint8_t *buffer = malloc(cap);
    size_t n = compression_encode_buffer(buffer, cap, dataset.bytes, dataset.length, NULL, COMPRESSION_ZLIB);
    NSMutableData *file = [[plain subdataWithRange:NSMakeRange(0, at)] mutableCopy];
    [file appendBytes:buffer length:n];
    free(buffer);
    NSError *error = nil;
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:file error:&error];
    XCTAssertNotNil(f, @"%@", error);
    float out[6];
    XCTAssertTrue([f decodeFrame:0 into:out error:&error], @"%@", error);
    for (int i = 0; i < 6; i++) XCTAssertEqual(out[i], values[i]);
}

- (void)testUnsupportedAndDamaged
{
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    [w us:0x0028 :0x0010 value:2];
    [w us:0x0028 :0x0011 value:2];
    [w us:0x0028 :0x0100 value:16];
    [w encapsulatedPixelData:@[[NSData dataWithBytes:"\xFF\xD8\xFF\xF7" length:4]] offsetTable:nil];
    BKDicomFile *f = [[BKDicomFile alloc] initWithData:[w fileWithTransferSyntax:@"1.2.840.10008.1.2.4.80"] error:nil];
    XCTAssertNotNil(f);
    XCTAssertFalse(f.canDecode);
    XCTAssertTrue([f.unsupportedReason containsString:@"JPEG-LS"], @"%@", f.unsupportedReason);
    float out[4];
    NSError *error = nil;
    XCTAssertFalse([f decodeFrame:0 into:out error:&error]);
    XCTAssertNotNil(error);

    // Cut in the middle of the pixel data: readable header, honest "incomplete" instead of garbage.
    int16_t values[64] = { 0 };
    NSData *slice = BKTestCTSlice(BKTestEncodingExplicitLE, kExplicitLE, 8, 8, values, 0, 1, @"1.2");
    BKDicomFile *cut = [[BKDicomFile alloc] initWithData:[slice subdataWithRange:NSMakeRange(0, slice.length - 20)] error:nil];
    XCTAssertNotNil(cut);
    XCTAssertFalse(cut.canDecode);
    XCTAssertTrue([cut.unsupportedReason containsString:@"shorter"], @"%@", cut.unsupportedReason);

    // Not DICOM at all.
    XCTAssertNil([[BKDicomFile alloc] initWithData:[@"hello, this is a text file and not an image" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertEqual(error.code, BKDicomErrorCodeNotDicom);
    // Damaged: a length running past the end of the header.
    NSMutableData *bad = [NSMutableData dataWithLength:128];
    [bad appendBytes:"DICM\x02\x00\x10\x00UI\xFF\x7F" length:12];
    XCTAssertNil([[BKDicomFile alloc] initWithData:bad error:&error]);
}

// ---- Series sorting and volume geometry ---------------------------------------------------------------------

- (void)testSeriesSortingShuffledWithDuplicate
{
    BKDicomSlice s[6];
    double zs[6] = { 4, 0, 6, 2, 8, 4 };   // shuffled, one duplicate
    for (int i = 0; i < 6; i++) {
        s[i].hasGeometry = 1;
        s[i].position = BKV3d(-5, -5, zs[i]);
        s[i].rowDirection = BKV3d(1, 0, 0);
        s[i].columnDirection = BKV3d(0, 1, 0);
        s[i].instanceNumber = i;
        s[i].sourceIndex = (uint32_t)i;
    }
    BKDicomSeriesOrder o;
    XCTAssertTrue(BKDicomSeriesSort(s, 6, 1, &o));
    XCTAssertEqual(o.count, 5u);
    XCTAssertEqual(o.order[0], 1u); XCTAssertEqual(o.order[1], 3u); XCTAssertEqual(o.order[4], 4u);
    XCTAssertEqualWithAccuracy(o.sliceSpacing, 2, 1e-12);
    XCTAssertTrue(o.warnings & BKSeriesWarningDuplicates);
    XCTAssertFalse(o.warnings & BKSeriesWarningUneven);
    free(o.order);

    // Gantry tilt: positions shift in y as z grows -> sheared step kept, warning set.
    for (int i = 0; i < 5; i++) s[i].position = BKV3d(0, i * 0.5, i * 2.0);
    XCTAssertTrue(BKDicomSeriesSort(s, 5, 1, &o));
    XCTAssertTrue(o.warnings & BKSeriesWarningTilted);
    XCTAssertEqualWithAccuracy(o.sliceStep.y, 0.5, 1e-12);
    XCTAssertEqualWithAccuracy(o.sliceSpacing, 2.0, 1e-12);
    free(o.order);
}

- (void)testAffineInverseAndLetters
{
    double m[16] = { 0.5, 0, 0, 0,   0, 0, -0.25, 0,   0, 2, 0, 0,   10, 20, 30, 1 };
    double inv[16], back[3];
    XCTAssertTrue(BKDicomInvertAffine(m, inv));
    double p[3] = { 10 + 0.5 * 3, 20 + 2 * 5, 30 - 0.25 * 7 };
    for (int r = 0; r < 3; r++) back[r] = inv[r] * p[0] + inv[4 + r] * p[1] + inv[8 + r] * p[2] + inv[12 + r];
    XCTAssertEqualWithAccuracy(back[0], 3, 1e-12);
    XCTAssertEqualWithAccuracy(back[1], 7, 1e-12);
    XCTAssertEqualWithAccuracy(back[2], 5, 1e-12);
    char letters[4];
    BKDicomOrientationLetters(BKV3d(1, 0, 0), 0.25, letters); XCTAssertEqual(strcmp(letters, "L"), 0);
    BKDicomOrientationLetters(BKV3d(0, 0, -1), 0.25, letters); XCTAssertEqual(strcmp(letters, "F"), 0);
    BKDicomOrientationLetters(BKV3d(-0.2, -0.6, 0.77), 0.25, letters); XCTAssertEqual(strcmp(letters, "HA"), 0);
}

// Volume from shuffled single-frame files, with a 2x reduction.
- (void)testVolumeFromFilesAndReduction
{
    uint32_t rows = 8, cols = 6;
    NSMutableArray<BKDicomFile *> *files = [NSMutableArray array];
    int order[4] = { 2, 0, 3, 1 };
    for (int i = 0; i < 4; i++) {
        int k = order[i];
        int16_t v[48];
        for (int j = 0; j < 48; j++) v[j] = (int16_t)(k * 100 + j);
        [files addObject:[[BKDicomFile alloc] initWithData:BKTestCTSlice(BKTestEncodingExplicitLE, kExplicitLE, rows, cols, v, 1.5 * k, 10 + k, @"1.5") error:nil]];
    }
    NSError *error = nil;
    BKDicomVolume *vol = [BKDicomVolume volumeWithFiles:files maximumVoxels:0 progress:nil error:&error];
    XCTAssertNotNil(vol, @"%@", error);
    XCTAssertEqual(vol.width, cols); XCTAssertEqual(vol.height, rows); XCTAssertEqual(vol.depth, 4u);
    const float *vox = vol.voxels.bytes;
    XCTAssertEqual(vox[2 * 48 + 7], 207);
    double toVoxel[16];
    [vol getPatientToVoxel:toVoxel];
    // Patient point of voxel (i=3, j=5, k=2): (-10 + 3*0.25, -20 + 5*0.5, 3.0)
    double p[3] = { -10 + 0.75, -20 + 2.5, 3.0 }, q[3];
    for (int r = 0; r < 3; r++) q[r] = toVoxel[r] * p[0] + toVoxel[4 + r] * p[1] + toVoxel[8 + r] * p[2] + toVoxel[12 + r];
    XCTAssertEqualWithAccuracy(q[0], 3, 1e-9); XCTAssertEqualWithAccuracy(q[1], 5, 1e-9); XCTAssertEqualWithAccuracy(q[2], 2, 1e-9);

    BKDicomVolume *small = [BKDicomVolume volumeWithFiles:files maximumVoxels:4 * 4 * 3 progress:nil error:&error];
    XCTAssertEqual(small.downsampleFactor, 2u);
    XCTAssertEqual(small.width, 3u); XCTAssertEqual(small.height, 4u);
    XCTAssertEqualWithAccuracy(small.spacingX, 0.5, 1e-12);
    const float *sv = small.voxels.bytes;
    XCTAssertEqualWithAccuracy(sv[0], (0 + 1 + 6 + 7) / 4.0, 1e-5);
    XCTAssertTrue(small.warnings.count > 0);

    // Cancelling stops and reports it.
    BKDicomVolume *cancelled = [BKDicomVolume volumeWithFiles:files maximumVoxels:0 progress:^BOOL(double f) { return NO; } error:&error];
    XCTAssertNil(cancelled);
}

@end
