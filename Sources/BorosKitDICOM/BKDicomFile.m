// BorosKitDICOM: BKDicomFile - see BKDicomFile.h. ARC.
//
// Original BorosKit code written for this project; contains no third-party code.

#import "BKDicomFile.h"
#import "BKDicomCore.h"
#import "BKJpegLosslessCore.h"
#import "BKRleCore.h"

#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <compression.h>

NSErrorDomain const BKDicomErrorDomain = @"BKDicomErrorDomain";

static NSError *BKDicomError(BKDicomErrorCode code, NSString *text)
{
    return [NSError errorWithDomain:BKDicomErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: text ?: @"DICOM error"}];
}

// What: text of a DICOM string field. UTF-8 when the file says ISO_IR 192 or the bytes are valid UTF-8,
// otherwise Latin-1 (the DICOM default repertoire is a subset of it).
static NSString *BKString(const char *value, const char *characterSet)
{
    if (value == NULL || value[0] == 0) return @"";
    NSString *s = nil;
    if (strstr(characterSet, "ISO_IR 192") != NULL || strstr(characterSet, "ISO_IR 6") == NULL)
        s = [NSString stringWithUTF8String:value];
    if (s == nil) s = [[NSString alloc] initWithCString:value encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

// What: inflates raw DEFLATE data (the dataset of a deflated DICOM file) with Apple's Compression framework.
static NSData *BKInflate(const uint8_t *bytes, size_t length)
{
    compression_stream stream;
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) return nil;
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[65536];
    stream.src_ptr = bytes;
    stream.src_size = length;
    compression_status status;
    do {
        stream.dst_ptr = buffer;
        stream.dst_size = sizeof(buffer);
        status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        if (status == COMPRESSION_STATUS_ERROR) { compression_stream_destroy(&stream); return nil; }
        [output appendBytes:buffer length:sizeof(buffer) - stream.dst_size];
    } while (status == COMPRESSION_STATUS_OK);
    compression_stream_destroy(&stream);
    return output;
}

@implementation BKDicomFile {
    BKDicomInfo _info;
    NSData *_data;          // the buffer _info's offsets point into (inflated for deflated files)
    NSString *_reason;
}

+ (instancetype)fileWithURL:(NSURL *)url error:(NSError **)error
{
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (data == nil) {
        if (error) *error = BKDicomError(BKDicomErrorCodeNotDicom, readError.localizedDescription ?: @"The file could not be read.");
        return nil;
    }
    return [[self alloc] initWithData:data error:error];
}

- (instancetype)initWithData:(NSData *)data error:(NSError **)error
{
    if ((self = [super init])) {
        char message[BK_DICOM_MESSAGE] = { 0 };
        BKDicomStatus status = BKDicomParseFile(data.bytes, data.length, &_info, message);
        _data = data;
        if (status == BKDicomErrorNeedsInflate) {
            // Deflated dataset: inflate everything after the file meta, then read it as explicit VR LE.
            NSData *inflated = BKInflate((const uint8_t *)data.bytes + _info.datasetOffset, data.length - _info.datasetOffset);
            if (inflated == nil) {
                BKDicomInfoFree(&_info);
                if (error) *error = BKDicomError(BKDicomErrorCodeDamaged, @"The deflated DICOM data could not be unpacked.");
                return nil;
            }
            BKDicomSyntax syntax = BKDicomSyntaxFromUID("1.2.840.10008.1.2.1");
            snprintf(syntax.name, sizeof(syntax.name), "Deflated Explicit VR Little Endian");
            status = BKDicomParseDataset(inflated.bytes, inflated.length, syntax, &_info, message);
            _data = inflated;
        }
        if (status != BKDicomOK) {
            BKDicomInfoFree(&_info);
            if (error) *error = BKDicomError(status == BKDicomErrorNotDicom ? BKDicomErrorCodeNotDicom : BKDicomErrorCodeDamaged,
                                             [NSString stringWithUTF8String:message] ?: @"Damaged DICOM file.");
            return nil;
        }
        if (!BKDicomCanDecode(&_info, message)) _reason = [NSString stringWithUTF8String:message];
    }
    return self;
}

- (void)dealloc
{
    BKDicomInfoFree(&_info);
}

- (NSData *)data { return _data; }

#define BK_STRING_GETTER(name, field) - (NSString *)name { return BKString(_info.field, _info.characterSet); }
BK_STRING_GETTER(patientName, patientName)
BK_STRING_GETTER(patientID, patientID)
BK_STRING_GETTER(patientBirthDate, patientBirthDate)
BK_STRING_GETTER(patientSex, patientSex)
BK_STRING_GETTER(studyInstanceUID, studyInstanceUID)
BK_STRING_GETTER(seriesInstanceUID, seriesInstanceUID)
BK_STRING_GETTER(sopInstanceUID, sopInstanceUID)
BK_STRING_GETTER(sopClassUID, sopClassUID)
BK_STRING_GETTER(frameOfReferenceUID, frameOfReferenceUID)
BK_STRING_GETTER(studyDate, studyDate)
BK_STRING_GETTER(studyTime, studyTime)
BK_STRING_GETTER(seriesDate, seriesDate)
BK_STRING_GETTER(seriesTime, seriesTime)
BK_STRING_GETTER(studyDescription, studyDescription)
BK_STRING_GETTER(seriesDescription, seriesDescription)
BK_STRING_GETTER(modality, modality)
BK_STRING_GETTER(bodyPart, bodyPart)
BK_STRING_GETTER(manufacturer, manufacturer)
BK_STRING_GETTER(modelName, modelName)
BK_STRING_GETTER(photometricInterpretation, photometric)
BK_STRING_GETTER(transferSyntaxUID, transferSyntaxUID)

- (NSString *)transferSyntaxName { return [NSString stringWithUTF8String:_info.syntax.name] ?: @""; }

- (NSString *)displayPatientName
{
    NSArray<NSString *> *parts = [self.patientName componentsSeparatedByString:@"^"];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [kept addObject:t];
    }
    if (kept.count >= 2) return [NSString stringWithFormat:@"%@, %@", kept[0], [[kept subarrayWithRange:NSMakeRange(1, kept.count - 1)] componentsJoinedByString:@" "]];
    return kept.firstObject ?: @"";
}

- (NSInteger)seriesNumber { return _info.seriesNumber == INT32_MIN ? NSNotFound : _info.seriesNumber; }
- (NSInteger)instanceNumber { return _info.instanceNumber == INT32_MIN ? NSNotFound : _info.instanceNumber; }
- (NSUInteger)rows { return _info.rows; }
- (NSUInteger)columns { return _info.columns; }
- (NSUInteger)numberOfFrames { return _info.numberOfFrames; }
- (NSUInteger)samplesPerPixel { return _info.samplesPerPixel; }
- (NSUInteger)bitsAllocated { return _info.bitsAllocated; }
- (NSUInteger)bitsStored { return _info.bitsStored; }
- (BOOL)signedPixels { return _info.pixelRepresentation == 1; }
- (BOOL)monochrome1 { return strcmp(_info.photometric, "MONOCHROME1") == 0; }
- (BOOL)hasPixelSpacing { return _info.hasPixelSpacing != 0; }
- (double)pixelSpacingX { return _info.pixelSpacing[1]; }
- (double)pixelSpacingY { return _info.pixelSpacing[0]; }
- (double)sliceThickness { return _info.sliceThickness; }
- (double)spacingBetweenSlices { return _info.spacingBetweenSlices; }
- (double)rescaleSlope { return _info.rescaleSlope; }
- (double)rescaleIntercept { return _info.rescaleIntercept; }
- (double)windowCenter { return _info.windowCenter; }
- (double)windowWidth { return _info.windowWidth; }
- (BOOL)canDecode { return _reason == nil; }
- (NSString *)unsupportedReason { return _reason; }

- (BOOL)getPosition:(double *)position orientation:(double *)orientation forFrame:(NSUInteger)frame
{
    double p[3], o[6];
    if (!BKDicomFrameOrientation(&_info, (uint32_t)frame, o) || !BKDicomFramePosition(&_info, (uint32_t)frame, p)) return NO;
    if (position) memcpy(position, p, sizeof(p));
    if (orientation) memcpy(orientation, o, sizeof(o));
    return YES;
}

#pragma mark Decoding

// What: a copy of the info describing a decoded frame laid out as little-endian 16-bit samples
// (sample-interleaved), so the shared BKDicomStoredToValues does the masking, sign and rescale.
- (BKDicomInfo)infoForDecoded16
{
    BKDicomInfo copy = _info;
    copy.bitsAllocated = 16;
    if (copy.bitsStored > 16) copy.bitsStored = 16;
    copy.highBit = copy.bitsStored - 1;
    copy.planarConfiguration = 0;
    return copy;
}

- (BOOL)decodeFrame:(NSUInteger)frame into:(float *)values error:(NSError **)error
{
    if (_reason) { if (error) *error = BKDicomError(BKDicomErrorCodeUnsupported, _reason); return NO; }
    if (frame >= _info.numberOfFrames) { if (error) *error = BKDicomError(BKDicomErrorCodeDamaged, @"No such frame."); return NO; }
    char message[BK_DICOM_MESSAGE] = { 0 };
    const uint8_t *bytes = _data.bytes;
    size_t size = _data.length;
    if (!_info.syntax.encapsulated) {
        if (!BKDicomDecodeNativeFrame(&_info, bytes, size, (uint32_t)frame, values, message)) {
            if (error) *error = BKDicomError(BKDicomErrorCodeDamaged, [NSString stringWithUTF8String:message]);
            return NO;
        }
        return YES;
    }
    size_t length = 0;
    uint8_t *frameBytes = BKDicomCopyFrameBytes(&_info, bytes, size, (uint32_t)frame, &length);
    if (frameBytes == NULL) {
        if (error) *error = BKDicomError(BKDicomErrorCodeDamaged, @"The compressed frame could not be found in the file.");
        return NO;
    }
    BOOL ok = NO;
    switch (_info.syntax.compression) {
        case BKDicomCompressionJPEGLossless: ok = [self decodeJpegLossless:frameBytes length:length frame:frame into:values message:message]; break;
        case BKDicomCompressionRLE: ok = [self decodeRle:frameBytes length:length frame:frame into:values message:message]; break;
        case BKDicomCompressionJPEGBaseline:
        case BKDicomCompressionJPEGExtended:
        case BKDicomCompressionJPEG2000: ok = [self decodeImageIO:frameBytes length:length frame:frame into:values message:message]; break;
        default: snprintf(message, sizeof(message), "Images compressed as %s cannot be opened yet.", _info.syntax.name); break;
    }
    free(frameBytes);
    if (!ok && error) *error = BKDicomError(BKDicomErrorCodeUnsupported, [NSString stringWithUTF8String:message] ?: @"Decoding failed.");
    return ok;
}

- (BOOL)decodeJpegLossless:(const uint8_t *)bytes length:(size_t)length frame:(NSUInteger)frame into:(float *)values message:(char *)message
{
    BKJpegLosslessImage image;
    if (!BKJpegLosslessReadHeader(bytes, length, &image, message)) return NO;
    if (image.width != _info.columns || image.height != _info.rows || image.components != _info.samplesPerPixel) {
        snprintf(message, BK_DICOM_MESSAGE, "The JPEG image size (%ux%u, %u components) does not match the DICOM header.",
                 image.width, image.height, image.components);
        return NO;
    }
    size_t count = (size_t)image.width * image.height * image.components;
    uint16_t *samples = malloc(count * sizeof(uint16_t));
    if (!samples) { snprintf(message, BK_DICOM_MESSAGE, "Out of memory."); return NO; }
    BOOL ok = BKJpegLosslessDecode(bytes, length, samples, count, &image, message);
    if (ok) {
        BKDicomInfo info = [self infoForDecoded16];
        // uint16 in memory is little endian on every Apple CPU; BKDicomStoredToValues reads little endian.
        ok = BKDicomStoredToValues(&info, (uint32_t)frame, (const uint8_t *)samples, count * 2, 0, 0, values);
        if (!ok) snprintf(message, BK_DICOM_MESSAGE, "The pixel layout is not supported.");
    }
    free(samples);
    return ok;
}

- (BOOL)decodeRle:(const uint8_t *)bytes length:(size_t)length frame:(NSUInteger)frame into:(float *)values message:(char *)message
{
    uint32_t bytesPerSample = _info.bitsAllocated / 8;
    size_t pixels = (size_t)_info.rows * _info.columns;
    size_t total = pixels * _info.samplesPerPixel * bytesPerSample;
    uint8_t *decoded = malloc(total);
    if (!decoded) { snprintf(message, BK_DICOM_MESSAGE, "Out of memory."); return NO; }
    BOOL ok = BKRleDecodeFrame(bytes, length, pixels, _info.samplesPerPixel, bytesPerSample, decoded, message);
    if (ok) {
        BKDicomInfo info = _info;
        info.planarConfiguration = 0;   // the RLE decoder interleaves the samples
        ok = BKDicomStoredToValues(&info, (uint32_t)frame, decoded, total, 0, 0, values);
        if (!ok) snprintf(message, BK_DICOM_MESSAGE, "The pixel layout is not supported.");
    }
    free(decoded);
    return ok;
}

// What: JPEG baseline / extended and JPEG 2000 frames through Apple ImageIO. The decoded CGImage's own
// bytes are read (no colour conversion, no drawing), so grey values arrive unchanged.
- (BOOL)decodeImageIO:(const uint8_t *)bytes length:(size_t)length frame:(NSUInteger)frame into:(float *)values message:(char *)message
{
    BOOL j2k = _info.syntax.compression == BKDicomCompressionJPEG2000;
    NSData *wrapped = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceTypeIdentifierHint: j2k ? @"public.jpeg-2000" : @"public.jpeg",
                              (__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)wrapped, (__bridge CFDictionaryRef)options);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
    if (source) CFRelease(source);
    if (image == NULL) {
        snprintf(message, BK_DICOM_MESSAGE, "%s", _info.syntax.compression == BKDicomCompressionJPEGExtended
                 ? "This 12-bit JPEG (extended) image cannot be decoded on this device."
                 : (j2k ? "The JPEG 2000 image could not be decoded." : "The JPEG image could not be decoded."));
        return NO;
    }
    BOOL ok = NO;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    size_t bpc = CGImageGetBitsPerComponent(image), bpp = CGImageGetBitsPerPixel(image), rowBytes = CGImageGetBytesPerRow(image);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(image);
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
    size_t channels = bpc ? bpp / bpc : 0;
    CFDataRef pixelData = NULL;
    if (width != _info.columns || height != _info.rows) {
        snprintf(message, BK_DICOM_MESSAGE, "The compressed image size (%zux%zu) does not match the DICOM header.", width, height);
    } else if ((bpc != 8 && bpc != 16) || channels == 0 || (bitmapInfo & kCGBitmapFloatComponents)) {
        snprintf(message, BK_DICOM_MESSAGE, "The decoded image format (%zu bits) is not supported.", bpc);
    } else if (bpc == 8 && _info.bitsStored > 8) {
        // Never lose precision silently: a 12/16-bit image that the system decoder only gives back as 8 bits
        // would show wrong Hounsfield values.
        snprintf(message, BK_DICOM_MESSAGE, "This %s image has %u-bit pixels, but the system decoder returned only 8 bits.",
                 j2k ? "JPEG 2000" : "JPEG", _info.bitsStored);
    } else if ((pixelData = CGDataProviderCopyData(CGImageGetDataProvider(image))) == NULL) {
        snprintf(message, BK_DICOM_MESSAGE, "The decoded image could not be read.");
    } else {
        // Which channels are colour: skip a leading or trailing alpha / padding channel.
        BOOL alphaFirst = alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaNoneSkipFirst;
        BOOL hasAlpha = alpha != kCGImageAlphaNone;
        size_t colourChannels = channels - (hasAlpha ? 1 : 0);
        size_t firstColour = (hasAlpha && alphaFirst) ? 1 : 0;
        CGBitmapInfo order = bitmapInfo & kCGBitmapByteOrderMask;
        BOOL little16 = order == kCGBitmapByteOrder16Little;   // 16-bit default / Big = big endian
        BOOL little32 = order == kCGBitmapByteOrder32Little;   // 8-bit BGRA-style packing
        size_t samples = _info.samplesPerPixel;
        if (!(colourChannels == samples || (samples == 1 && colourChannels == 3) || (samples == 3 && colourChannels == 1))) {
            snprintf(message, BK_DICOM_MESSAGE, "The decoded image has %zu colour channels, %zu expected.", colourChannels, samples);
        } else {
            const uint8_t *src = CFDataGetBytePtr(pixelData);
            size_t count = width * height * samples;
            uint16_t *decoded = malloc(count * sizeof(uint16_t));
            if (decoded == NULL) {
                snprintf(message, BK_DICOM_MESSAGE, "Out of memory.");
            } else {
                for (size_t y = 0; y < height; y++) {
                    const uint8_t *row = src + y * rowBytes;
                    for (size_t x = 0; x < width; x++) {
                        uint16_t c[4] = { 0, 0, 0, 0 };
                        for (size_t k = 0; k < channels && k < 4; k++) {
                            size_t ch = k;
                            if (bpc == 8 && little32 && channels == 4) ch = 3 - k;   // stored reversed in memory
                            if (bpc == 8) c[k] = row[x * channels + ch];
                            else {
                                const uint8_t *p = row + (x * channels + ch) * 2;
                                c[k] = little16 ? (uint16_t)(p[0] | (p[1] << 8)) : (uint16_t)((p[0] << 8) | p[1]);
                            }
                        }
                        const uint16_t *colour = c + firstColour;
                        uint16_t *dst = decoded + (y * width + x) * samples;
                        if (samples == colourChannels) for (size_t s = 0; s < samples; s++) dst[s] = colour[s];
                        else if (samples == 1) dst[0] = (uint16_t)(0.299 * colour[0] + 0.587 * colour[1] + 0.114 * colour[2] + 0.5);
                        else dst[0] = dst[1] = dst[2] = colour[0];
                    }
                }
                BKDicomInfo info = [self infoForDecoded16];
                if (samples == 3) {
                    // ImageIO already turned YBR into RGB.
                    snprintf(info.photometric, sizeof(info.photometric), "RGB");
                }
                ok = BKDicomStoredToValues(&info, (uint32_t)frame, (const uint8_t *)decoded, count * 2, 0, 0, values);
                if (!ok) snprintf(message, BK_DICOM_MESSAGE, "The pixel layout is not supported.");
                free(decoded);
            }
        }
    }
    if (pixelData) CFRelease(pixelData);
    CGImageRelease(image);
    return ok;
}

@end
