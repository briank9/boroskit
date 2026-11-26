// BorosKitDICOMTests: BKTestDicomWriter - see BKTestDicomWriter.h.
// Original BorosKit code written for this project; contains no third-party code.

#import "BKTestDicomWriter.h"

static BOOL BKIsLong(NSString *vr)
{
    return [@[@"OB", @"OD", @"OF", @"OL", @"OV", @"OW", @"SQ", @"UC", @"UN", @"UR", @"UT", @"SV", @"UV"] containsObject:vr];
}

@implementation BKTestDicomWriter {
    BKTestEncoding _encoding;
}

- (instancetype)initWithEncoding:(BKTestEncoding)encoding
{
    if ((self = [super init])) { _encoding = encoding; _body = [NSMutableData data]; }
    return self;
}

- (void)put16:(uint16_t)v into:(NSMutableData *)d
{
    uint8_t b[2];
    if (_encoding == BKTestEncodingExplicitBE) { b[0] = v >> 8; b[1] = v & 0xFF; } else { b[0] = v & 0xFF; b[1] = v >> 8; }
    [d appendBytes:b length:2];
}

- (void)put32:(uint32_t)v into:(NSMutableData *)d
{
    uint8_t b[4];
    if (_encoding == BKTestEncodingExplicitBE) { b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; }
    else { b[0] = v; b[1] = v >> 8; b[2] = v >> 16; b[3] = v >> 24; }
    [d appendBytes:b length:4];
}

- (void)header:(uint16_t)g :(uint16_t)e vr:(NSString *)vr length:(uint32_t)len
{
    [self put16:g into:_body];
    [self put16:e into:_body];
    if (_encoding == BKTestEncodingImplicitLE) { [self put32:len into:_body]; return; }
    [_body appendBytes:vr.UTF8String length:2];
    if (BKIsLong(vr)) { uint16_t zero = 0; [_body appendBytes:&zero length:2]; [self put32:len into:_body]; }
    else [self put16:(uint16_t)len into:_body];
}

- (void)string:(uint16_t)g :(uint16_t)e vr:(NSString *)vr value:(NSString *)value
{
    NSMutableData *v = [[value dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (v.length & 1) { uint8_t pad = [vr isEqualToString:@"UI"] ? 0 : ' '; [v appendBytes:&pad length:1]; }
    [self header:g :e vr:vr length:(uint32_t)v.length];
    [_body appendData:v];
}

- (void)us:(uint16_t)g :(uint16_t)e value:(uint16_t)value
{
    [self header:g :e vr:@"US" length:2];
    [self put16:value into:_body];
}

- (void)raw:(uint16_t)g :(uint16_t)e vr:(NSString *)vr bytes:(NSData *)bytes
{
    [self header:g :e vr:vr length:(uint32_t)bytes.length];
    [_body appendData:bytes];
}

- (void)sequence:(uint16_t)g :(uint16_t)e items:(NSArray<NSData *> *)items undefinedLength:(BOOL)undefined
{
    NSMutableData *content = [NSMutableData data];
    for (NSData *item in items) {
        [self put16:0xFFFE into:content]; [self put16:0xE000 into:content];
        [self put32:undefined ? 0xFFFFFFFF : (uint32_t)item.length into:content];
        [content appendData:item];
        if (undefined) { [self put16:0xFFFE into:content]; [self put16:0xE00D into:content]; [self put32:0 into:content]; }
    }
    if (undefined) { [self put16:0xFFFE into:content]; [self put16:0xE0DD into:content]; [self put32:0 into:content]; }
    [self header:g :e vr:@"SQ" length:undefined ? 0xFFFFFFFF : (uint32_t)content.length];
    [_body appendData:content];
}

- (void)pixelData:(NSData *)bytes vr:(NSString *)vr
{
    NSMutableData *v = [bytes mutableCopy];
    if (v.length & 1) { uint8_t z = 0; [v appendBytes:&z length:1]; }
    [self raw:0x7FE0 :0x0010 vr:vr bytes:v];
}

- (void)encapsulatedPixelData:(NSArray<NSData *> *)fragments offsetTable:(NSArray<NSNumber *> *)table
{
    // Encapsulated data is always little endian.
    NSMutableData *d = [NSMutableData data];
    void (^p16)(uint16_t) = ^(uint16_t v) { uint8_t b[2] = { v & 0xFF, v >> 8 }; [d appendBytes:b length:2]; };
    void (^p32)(uint32_t) = ^(uint32_t v) { uint8_t b[4] = { v, v >> 8, v >> 16, v >> 24 }; [d appendBytes:b length:4]; };
    p16(0xFFFE); p16(0xE000); p32((uint32_t)table.count * 4);
    for (NSNumber *n in table) p32(n.unsignedIntValue);
    for (NSData *f in fragments) {
        NSMutableData *frag = [f mutableCopy];
        if (frag.length & 1) { uint8_t z = 0; [frag appendBytes:&z length:1]; }
        p16(0xFFFE); p16(0xE000); p32((uint32_t)frag.length);
        [d appendData:frag];
    }
    p16(0xFFFE); p16(0xE0DD); p32(0);
    [self header:0x7FE0 :0x0010 vr:@"OB" length:0xFFFFFFFF];
    [_body appendData:d];
}

- (NSData *)fileWithTransferSyntax:(NSString *)uid
{
    NSMutableData *file = [NSMutableData dataWithLength:128];
    [file appendBytes:"DICM" length:4];
    BKTestDicomWriter *meta = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    uint8_t version[2] = { 0, 1 };
    [meta raw:0x0002 :0x0001 vr:@"OB" bytes:[NSData dataWithBytes:version length:2]];
    [meta string:0x0002 :0x0002 vr:@"UI" value:@"1.2.840.10008.5.1.4.1.1.2"];
    [meta string:0x0002 :0x0003 vr:@"UI" value:@"1.2.3.4.5.6"];
    [meta string:0x0002 :0x0010 vr:@"UI" value:uid];
    BKTestDicomWriter *group = [[BKTestDicomWriter alloc] initWithEncoding:BKTestEncodingExplicitLE];
    uint32_t len = (uint32_t)meta.body.length;
    [group raw:0x0002 :0x0000 vr:@"UL" bytes:[NSData dataWithBytes:&len length:4]];
    [file appendData:group.body];
    [file appendData:meta.body];
    [file appendData:_body];
    return file;
}

@end

NSData *BKTestCTSlice(BKTestEncoding encoding, NSString *transferSyntax, uint32_t rows, uint32_t cols,
                      const int16_t *values, double z, int instance, NSString *seriesUID)
{
    BKTestDicomWriter *w = [[BKTestDicomWriter alloc] initWithEncoding:encoding];
    [w string:0x0008 :0x0060 vr:@"CS" value:@"CT"];
    [w string:0x0010 :0x0010 vr:@"PN" value:@"Phantom^Test"];
    [w string:0x0020 :0x000D vr:@"UI" value:@"1.2.826.0.1.3680043.9.9999.1"];
    [w string:0x0020 :0x000E vr:@"UI" value:seriesUID];
    [w string:0x0020 :0x0013 vr:@"IS" value:[NSString stringWithFormat:@"%d", instance]];
    [w string:0x0020 :0x0032 vr:@"DS" value:[NSString stringWithFormat:@"-10\\-20\\%g", z]];
    [w string:0x0020 :0x0037 vr:@"DS" value:@"1\\0\\0\\0\\1\\0"];
    [w us:0x0028 :0x0002 value:1];
    [w string:0x0028 :0x0004 vr:@"CS" value:@"MONOCHROME2"];
    [w us:0x0028 :0x0010 value:(uint16_t)rows];
    [w us:0x0028 :0x0011 value:(uint16_t)cols];
    [w string:0x0028 :0x0030 vr:@"DS" value:@"0.5\\0.25"];
    [w us:0x0028 :0x0100 value:16];
    [w us:0x0028 :0x0101 value:16];
    [w us:0x0028 :0x0102 value:15];
    [w us:0x0028 :0x0103 value:0];
    [w string:0x0028 :0x1052 vr:@"DS" value:@"-1024"];
    [w string:0x0028 :0x1053 vr:@"DS" value:@"1"];
    NSMutableData *pixels = [NSMutableData dataWithLength:rows * cols * 2];
    uint8_t *p = pixels.mutableBytes;
    for (uint32_t i = 0; i < rows * cols; i++) {
        uint16_t stored = (uint16_t)(values[i] + 1024);
        if (encoding == BKTestEncodingExplicitBE) { p[2 * i] = stored >> 8; p[2 * i + 1] = stored & 0xFF; }
        else { p[2 * i] = stored & 0xFF; p[2 * i + 1] = stored >> 8; }
    }
    [w pixelData:pixels vr:@"OW"];
    return [w fileWithTransferSyntax:transferSyntax];
}

// ---- Lossless JPEG test encoder -----------------------------------------------------------------------

typedef struct { NSMutableData *out; uint32_t buffer; int bits; } BKBitWriter;

static void BKPutByte(BKBitWriter *w, uint8_t b)
{
    [w->out appendBytes:&b length:1];
    if (b == 0xFF) { uint8_t z = 0; [w->out appendBytes:&z length:1]; }   // byte stuffing
}

static void BKPutBits(BKBitWriter *w, uint32_t value, int n)
{
    for (int i = n - 1; i >= 0; i--) {
        w->buffer = (w->buffer << 1) | ((value >> i) & 1);
        if (++w->bits == 8) { BKPutByte(w, (uint8_t)w->buffer); w->buffer = 0; w->bits = 0; }
    }
}

static void BKFlushBits(BKBitWriter *w)
{
    while (w->bits != 0) BKPutBits(w, 1, 1);   // pad with 1 bits
}

static void BKMarker(NSMutableData *d, uint8_t m) { uint8_t b[2] = { 0xFF, m }; [d appendBytes:b length:2]; }
static void BKBE16(NSMutableData *d, uint32_t v) { uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v }; [d appendBytes:b length:2]; }

static int32_t BKHalf(int32_t x) { return (x - (x & 1)) / 2; }

NSData *BKTestEncodeJpegLossless(const uint16_t *samples, uint32_t W, uint32_t H, uint32_t NC,
                                 uint32_t precision, int predictor, int Pt, uint32_t restartInterval)
{
    // Our own made-up prefix code: categories 0-5 get 3-bit codes, 6-16 get 6-bit codes (valid: 6/8 + 11/64 < 1).
    uint8_t counts[16] = { 0 };
    counts[2] = 6; counts[5] = 11;
    uint32_t code[17]; int length[17];
    uint32_t c = 0; int k = 0;
    for (int len = 1; len <= 16; len++) {
        for (int i = 0; i < counts[len - 1]; i++, k++, c++) { code[k] = c; length[k] = len; }
        c <<= 1;
    }
    NSMutableData *d = [NSMutableData data];
    BKMarker(d, 0xD8);
    BKMarker(d, 0xC3);
    BKBE16(d, 8 + 3 * NC);
    uint8_t p = (uint8_t)precision; [d appendBytes:&p length:1];
    BKBE16(d, H); BKBE16(d, W);
    uint8_t nc = (uint8_t)NC; [d appendBytes:&nc length:1];
    for (uint32_t i = 0; i < NC; i++) { uint8_t comp[3] = { (uint8_t)(i + 1), 0x11, 0 }; [d appendBytes:comp length:3]; }
    BKMarker(d, 0xC4);
    BKBE16(d, 2 + 1 + 16 + 17);
    uint8_t tc = 0x00; [d appendBytes:&tc length:1];
    [d appendBytes:counts length:16];
    for (uint8_t v = 0; v <= 16; v++) [d appendBytes:&v length:1];
    if (restartInterval) { BKMarker(d, 0xDD); BKBE16(d, 4); BKBE16(d, restartInterval); }
    BKMarker(d, 0xDA);
    BKBE16(d, 6 + 2 * NC);
    [d appendBytes:&nc length:1];
    for (uint32_t i = 0; i < NC; i++) { uint8_t comp[2] = { (uint8_t)(i + 1), 0x00 }; [d appendBytes:comp length:2]; }
    uint8_t tail[3] = { (uint8_t)predictor, 0, (uint8_t)Pt };
    [d appendBytes:tail length:3];

    BKBitWriter w = { d, 0, 0 };
    int32_t initial = 1 << (precision - Pt - 1);
    int firstLine = 1, reset = 1;
    uint32_t left = restartInterval, mcus = 0, rst = 0;
    for (uint32_t y = 0; y < H; y++) {
        for (uint32_t x = 0; x < W; x++) {
            if (restartInterval && mcus > 0 && left == 0) {
                BKFlushBits(&w);
                BKMarker(d, (uint8_t)(0xD0 + (rst++ & 7)));
                left = restartInterval; firstLine = 1; reset = 1;
            }
            for (uint32_t ci = 0; ci < NC; ci++) {
                size_t here = ((size_t)y * W + x) * NC + ci;
                #define S(i) ((int32_t)(samples[(i)] >> Pt))
                int32_t pred;
                if (reset) pred = initial;
                else if (firstLine) pred = S(here - NC);
                else if (x == 0) pred = S(here - (size_t)W * NC);
                else {
                    int32_t a = S(here - NC), b = S(here - (size_t)W * NC), cc = S(here - (size_t)W * NC - NC);
                    switch (predictor) {
                        case 1: pred = a; break; case 2: pred = b; break; case 3: pred = cc; break;
                        case 4: pred = a + b - cc; break; case 5: pred = a + BKHalf(b - cc); break;
                        case 6: pred = b + BKHalf(a - cc); break; default: pred = BKHalf(a + b); break;
                    }
                }
                int32_t diff = (S(here) - pred) & 0xFFFF;
                #undef S
                int cat;
                uint32_t extra = 0;
                if (diff == 0x8000) cat = 16;
                else {
                    if (diff > 0x8000) diff -= 0x10000;
                    int32_t m = diff < 0 ? -diff : diff;
                    cat = 0;
                    while (m >> cat) cat++;
                    extra = diff >= 0 ? (uint32_t)diff : (uint32_t)(diff + (1 << cat) - 1);
                }
                BKPutBits(&w, code[cat], length[cat]);
                if (cat > 0 && cat < 16) BKPutBits(&w, extra & ((1u << cat) - 1), cat);
            }
            reset = 0;
            mcus++;
            if (restartInterval) left--;
        }
        firstLine = 0;
    }
    BKFlushBits(&w);
    BKMarker(d, 0xD9);
    return d;
}

// ---- RLE test encoder ---------------------------------------------------------------------------------

static void BKPackBits(const uint8_t *in, size_t n, NSMutableData *out)
{
    size_t i = 0;
    while (i < n) {
        size_t run = 1;
        while (i + run < n && run < 128 && in[i + run] == in[i]) run++;
        if (run >= 2) {
            int8_t h = (int8_t)(1 - (int)run);
            [out appendBytes:&h length:1];
            [out appendBytes:&in[i] length:1];
            i += run;
        } else {
            size_t lit = 1;
            while (i + lit < n && lit < 128 && !(i + lit + 1 < n && in[i + lit] == in[i + lit + 1])) lit++;
            int8_t h = (int8_t)(lit - 1);
            [out appendBytes:&h length:1];
            [out appendBytes:&in[i] length:lit];
            i += lit;
        }
    }
    if (out.length & 1) { int8_t nop = -128; [out appendBytes:&nop length:1]; }
}

NSData *BKTestEncodeRle(const uint8_t *pixels, size_t count, uint32_t samples, uint32_t bytesPerSample)
{
    uint32_t segments = samples * bytesPerSample;
    NSMutableData *body = [NSMutableData data];
    uint32_t header[16] = { segments };
    uint8_t *plane = malloc(count);
    for (uint32_t seg = 0; seg < segments; seg++) {
        header[1 + seg] = (uint32_t)(64 + body.length);
        uint32_t s = seg / bytesPerSample, fromTop = seg % bytesPerSample;
        for (size_t p = 0; p < count; p++)
            plane[p] = pixels[(p * samples + s) * bytesPerSample + (bytesPerSample - 1 - fromTop)];
        BKPackBits(plane, count, body);
    }
    free(plane);
    NSMutableData *out = [NSMutableData dataWithBytes:header length:64];
    [out appendData:body];
    return out;
}
