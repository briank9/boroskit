// BorosKitDICOM: BKDicomFile - one DICOM file, read with BorosKit's own reader (BKDicomCore), for macOS and iOS.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Thin Apple glue over the plain-C cores BKDicomCore / BKJpegLosslessCore / BKRleCore. The only Apple-
//   specific jobs here: reading / memory-mapping the file (Foundation), inflating "deflated" datasets
//   (Apple's Compression framework, raw DEFLATE), and decoding JPEG baseline / extended and JPEG 2000 with
//   Apple ImageIO. A Windows/Linux build replaces exactly these three with its platform's equivalents and
//   calls the same C cores; everything about the DICOM structure is in the cores.
//
// Plain language: open a file, read who / what / where from it, and turn any of its frames into a grid of
// numbers (Hounsfield units for CT / CBCT). Files that cannot be decoded say why in plain words
// (`unsupportedReason`) instead of producing a garbage picture.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BKDicomErrorDomain;

typedef NS_ERROR_ENUM(BKDicomErrorDomain, BKDicomErrorCode) {
    BKDicomErrorCodeNotDicom = 1,
    BKDicomErrorCodeDamaged = 2,
    BKDicomErrorCodeUnsupported = 3,
    BKDicomErrorCodeNoMemory = 4,
    BKDicomErrorCodeMismatch = 5,    // frames of one series do not fit together
    BKDicomErrorCodeCancelled = 6,
};

@interface BKDicomFile : NSObject

// What: reads the file (memory-mapped when possible). nil + error when it is not DICOM or is damaged.
// A readable DICOM file whose pixels cannot be decoded is still returned (canDecode = NO, with the reason).
+ (nullable instancetype)fileWithURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (nullable instancetype)initWithData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;

@property (nonatomic, readonly) NSData *data;

// Who / what / when ("" when missing). Names keep DICOM's '^' separators; see displayPatientName.
@property (nonatomic, readonly) NSString *patientName, *patientID, *patientBirthDate, *patientSex;
@property (nonatomic, readonly) NSString *studyInstanceUID, *seriesInstanceUID, *sopInstanceUID, *sopClassUID;
@property (nonatomic, readonly) NSString *frameOfReferenceUID;
@property (nonatomic, readonly) NSString *studyDate, *studyTime, *seriesDate, *seriesTime;
@property (nonatomic, readonly) NSString *studyDescription, *seriesDescription, *modality, *bodyPart;
@property (nonatomic, readonly) NSString *manufacturer, *modelName;
// "Doe^John" -> "Doe, John".
@property (nonatomic, readonly) NSString *displayPatientName;
@property (nonatomic, readonly) NSInteger seriesNumber, instanceNumber;   // NSNotFound when missing

// Pixel description.
@property (nonatomic, readonly) NSUInteger rows, columns, numberOfFrames, samplesPerPixel;
@property (nonatomic, readonly) NSUInteger bitsAllocated, bitsStored;
@property (nonatomic, readonly) BOOL signedPixels;
@property (nonatomic, readonly) NSString *photometricInterpretation;
@property (nonatomic, readonly) BOOL monochrome1;   // white = low values (display inverted)
@property (nonatomic, readonly) NSString *transferSyntaxUID, *transferSyntaxName;

// Geometry. pixelSpacingX = mm between columns, pixelSpacingY = mm between rows (1 when missing).
@property (nonatomic, readonly) BOOL hasPixelSpacing;
@property (nonatomic, readonly) double pixelSpacingX, pixelSpacingY, sliceThickness, spacingBetweenSlices;
// What: position (mm, 3 values) and orientation (row then column direction, 6 values) of one frame;
// NO when the file does not say.
- (BOOL)getPosition:(double *)position orientation:(double *)orientation forFrame:(NSUInteger)frame;

// Values.
@property (nonatomic, readonly) double rescaleSlope, rescaleIntercept;
@property (nonatomic, readonly) double windowCenter, windowWidth;   // width 0 = none given

// Decoding.
@property (nonatomic, readonly) BOOL canDecode;
@property (nonatomic, readonly, nullable) NSString *unsupportedReason;
// What: frame -> rows * columns floats (modality values; colour becomes luminance). NO + error on failure.
// Thread-safe: several frames of one file may be decoded at once.
- (BOOL)decodeFrame:(NSUInteger)frame into:(float *)values error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
