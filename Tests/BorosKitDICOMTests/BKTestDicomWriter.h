// BorosKitDICOMTests: a tiny writer of synthetic DICOM files for the tests (no real patient data).
// Original BorosKit code written for this project; contains no third-party code.
//
// What: builds DICOM byte streams element by element in any of the three uncompressed encodings, with
// sequences of defined or undefined length and encapsulated (compressed) pixel data. Also an original
// lossless-JPEG encoder and an RLE encoder, used only to make test input for the decoders.

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BKTestEncoding) {
    BKTestEncodingImplicitLE,
    BKTestEncodingExplicitLE,
    BKTestEncodingExplicitBE,
};

@interface BKTestDicomWriter : NSObject
- (instancetype)initWithEncoding:(BKTestEncoding)encoding;
@property (nonatomic, readonly) NSMutableData *body;   // the dataset bytes written so far
// Elements (the VR is written in explicit encodings; values are padded to even length as DICOM requires).
- (void)string:(uint16_t)group :(uint16_t)element vr:(NSString *)vr value:(NSString *)value;
- (void)us:(uint16_t)group :(uint16_t)element value:(uint16_t)value;
- (void)raw:(uint16_t)group :(uint16_t)element vr:(NSString *)vr bytes:(NSData *)bytes;
// Sequence: `items` are dataset bodies written with the same encoding; undefined = delimited lengths.
- (void)sequence:(uint16_t)group :(uint16_t)element items:(NSArray<NSData *> *)items undefinedLength:(BOOL)undefined;
// Native pixel data (bytes already in the file's byte order).
- (void)pixelData:(NSData *)bytes vr:(NSString *)vr;
// Encapsulated pixel data: offset table (may be empty) + fragments.
- (void)encapsulatedPixelData:(NSArray<NSData *> *)fragments offsetTable:(nullable NSArray<NSNumber *> *)table;
// A complete Part 10 file: preamble, "DICM", file meta (explicit LE) with the transfer syntax, then `body`.
- (NSData *)fileWithTransferSyntax:(NSString *)uid;
@end

// What: a standard CT-like slice as a file (explicit LE unless said otherwise), 16-bit signed values `values`
// (rows*cols), position z, axial orientation, 0.5 mm pixels, rescale -1024 / 1 (stored = value + 1024).
NSData *BKTestCTSlice(BKTestEncoding encoding, NSString *transferSyntax, uint32_t rows, uint32_t cols,
                      const int16_t *values, double z, int instance, NSString *seriesUID);

// What: original lossless-JPEG encoder (test only): samples are component-interleaved, `precision` bits.
NSData *BKTestEncodeJpegLossless(const uint16_t *samples, uint32_t width, uint32_t height, uint32_t components,
                                 uint32_t precision, int predictor, int pointTransform, uint32_t restartInterval);
// What: DICOM RLE encoder (test only): `pixels` pixels, interleaved samples, little-endian samples in memory.
NSData *BKTestEncodeRle(const uint8_t *pixels, size_t count, uint32_t samples, uint32_t bytesPerSample);

NS_ASSUME_NONNULL_END
