// BorosKitDICOM: BKDicomCore - a small, original DICOM file reader in plain C99.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 (<stdint.h>, <stddef.h>, <string.h>, <stdlib.h>, <math.h>); no Objective-C, no Apple
//   frameworks, no Horos-derived (LGPL) code, no DCMTK / GDCM. Compiles unchanged on Windows/Linux.
// - Nothing here touches the GPU. The parser works on a byte buffer the caller has read (or memory-
//   mapped); the Apple glue (BKDicomFile.m) only adds file reading, inflating "deflated" files and
//   JPEG / JPEG 2000 decoding through Apple ImageIO. A Windows/Linux build supplies those three.
// - Deterministic, no global state, thread-safe (every call works on its own BKDicomInfo).
// - Written from the DICOM standard's description of the file format (PS3.5 data structures and
//   encoding, PS3.10 file format, PS3.3 attribute meanings). No code or tables were copied.
//
// Plain language: a DICOM file is a list of "elements" (tag + value), e.g. (0010,0010) = patient name.
// This reader walks that list, keeps the ~45 elements an image viewer needs (who, when, which series,
// where each slice lies in the patient, how to turn stored numbers into Hounsfield units), finds the
// pixel data and turns the stored pixels into floating point values. It understands:
//   - Part 10 files ("DICM" after a 128-byte preamble) and bare datasets without the preamble;
//   - implicit VR little endian, explicit VR little endian, explicit VR big endian (retired);
//   - sequences and items of defined and undefined length (skipped properly, or read where the
//     geometry of "enhanced" multi-frame scans lives: the shared and per-frame functional groups);
//   - native (uncompressed) pixel data, 8 / 16 / 32 bits allocated, signed or unsigned, any bits
//     stored / high bit, MONOCHROME1 / MONOCHROME2 / RGB (planar 0 or 1) / YBR_FULL;
//   - encapsulated (compressed) pixel data: finds the fragments of each frame (basic offset table,
//     one fragment per frame, or frame starts found by their markers). Decoding: JPEG Lossless and
//     RLE here (BKJpegLosslessCore, BKRleCore); JPEG baseline / extended and JPEG 2000 by the glue.
// Anything else (JPEG-LS, HTJ2K, MPEG/H.264 video, 1-bit pixels, ...) gives a clear message.

#ifndef BK_DICOM_CORE_H
#define BK_DICOM_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Transfer syntax (how the file is encoded) -----------------------------------------------

typedef enum {
    BKDicomCompressionNone = 0,         // native pixel data
    BKDicomCompressionDeflate = 1,      // whole dataset deflated (1.2.840.10008.1.2.1.99): glue inflates
    BKDicomCompressionJPEGBaseline = 2, // 1.2.840.10008.1.2.4.50 (8-bit lossy): glue (ImageIO)
    BKDicomCompressionJPEGExtended = 3, // 1.2.840.10008.1.2.4.51 (12-bit lossy): glue (ImageIO, 8-bit only)
    BKDicomCompressionJPEGLossless = 4, // 1.2.840.10008.1.2.4.57 and .4.70 (process 14): BKJpegLosslessCore
    BKDicomCompressionJPEG2000 = 5,     // 1.2.840.10008.1.2.4.90 / .91: glue (ImageIO)
    BKDicomCompressionRLE = 6,          // 1.2.840.10008.1.2.5: BKRleCore
    BKDicomCompressionUnsupported = 7,  // anything else (JPEG-LS, HTJ2K, video, unknown)
} BKDicomCompression;

typedef struct {
    int32_t explicitVR;        // 1 = explicit VR, 0 = implicit VR
    int32_t bigEndian;         // 1 = big endian (retired 1.2.840.10008.1.2.2)
    int32_t encapsulated;      // 1 = pixel data stored as fragments (compressed)
    int32_t compression;       // BKDicomCompression
    char name[64];             // plain-language name, e.g. "JPEG Lossless (SV1)"
} BKDicomSyntax;

// What: what a transfer syntax UID means. Unknown UIDs give compression Unsupported (explicit LE
// assumed for walking, which is what every newer syntax uses). NULL / empty = implicit VR LE.
BKDicomSyntax BKDicomSyntaxFromUID(const char *uid);

// ---- The information kept from a file ------------------------------------------------------------

#define BK_DICOM_STRING 96   // longest string kept per element (longer values are cut, never overflow)

typedef struct {
    // who / what / when (strings are trimmed, '^' in names kept as-is)
    char patientName[BK_DICOM_STRING];
    char patientID[BK_DICOM_STRING];
    char patientBirthDate[16];
    char patientSex[16];
    char studyInstanceUID[72];
    char seriesInstanceUID[72];
    char sopInstanceUID[72];
    char sopClassUID[72];
    char frameOfReferenceUID[72];
    char studyDate[16];
    char studyTime[24];
    char seriesDate[16];
    char seriesTime[24];
    char studyDescription[BK_DICOM_STRING];
    char seriesDescription[BK_DICOM_STRING];
    char modality[16];
    char manufacturer[BK_DICOM_STRING];
    char modelName[BK_DICOM_STRING];
    char bodyPart[BK_DICOM_STRING];
    char transferSyntaxUID[72];
    char characterSet[64];         // (0008,0005), e.g. "ISO_IR 100" (Latin-1) or "ISO_IR 192" (UTF-8); the glue
                                   // uses it to turn the name bytes into text
    int32_t seriesNumber;         // INT32_MIN when missing
    int32_t instanceNumber;        // INT32_MIN when missing

    // image pixel description
    uint32_t rows, columns;
    uint32_t numberOfFrames;       // 1 when missing
    uint32_t samplesPerPixel;      // 1 when missing
    uint32_t planarConfiguration;  // 0 = R1G1B1 R2G2B2..., 1 = all R then all G then all B
    uint32_t bitsAllocated, bitsStored, highBit;
    uint32_t pixelRepresentation;  // 0 unsigned, 1 signed (two's complement)
    char photometric[24];          // "MONOCHROME2", "MONOCHROME1", "RGB", "YBR_FULL", ...

    // geometry (patient mm). has* = 1 when the file gave the value.
    int32_t hasPosition, hasOrientation, hasPixelSpacing;
    double imagePosition[3];       // centre of the first (top-left) pixel
    double imageOrientation[6];    // row direction (x of the image), then column direction (y)
    double pixelSpacing[2];        // DICOM order: [0] = between rows (y), [1] = between columns (x)
    double sliceThickness;         // 0 when missing
    double spacingBetweenSlices;   // 0 when missing
    double sliceLocation;          // NAN when missing

    // value conversion: modality value = stored * slope + intercept
    double rescaleSlope, rescaleIntercept;   // 1 and 0 when missing
    double windowCenter, windowWidth;        // first values; width 0 when missing

    // enhanced multi-frame: per-frame values (NULL when the file has none; frameCount entries)
    uint32_t perFrameCount;
    double *framePositions;        // 3 per frame; NAN where a frame had no position
    double *frameOrientations;     // 6 per frame; NAN where a frame had no orientation
    double *frameRescale;          // 2 per frame (slope, intercept); NAN where missing

    // where the pixel data is (offsets into the buffer that was parsed)
    BKDicomSyntax syntax;
    int32_t hasPixelData;
    size_t pixelDataOffset;        // native: first byte of the values
    size_t pixelDataLength;        // native: bytes (defined length)
    char pixelDataVR[3];           // "OB" / "OW" (explicit) or "OW" assumed (implicit)
    uint32_t fragmentCount;        // encapsulated: data fragments (the basic offset table not counted)
    size_t *fragmentOffsets;       // encapsulated: first byte of each fragment's data
    size_t *fragmentLengths;
    uint32_t offsetTableCount;     // encapsulated: entries of the basic offset table (0 = empty)
    uint32_t *offsetTable;         // byte offsets of frame starts, relative to the first fragment's item

    // deflated files: where the deflated dataset starts (the glue inflates from there and calls
    // BKDicomParseDataset on the result)
    size_t datasetOffset;
} BKDicomInfo;

typedef enum {
    BKDicomOK = 0,
    BKDicomErrorNotDicom = 1,      // no DICOM structure found
    BKDicomErrorTruncated = 2,     // the file ends in the middle of an element
    BKDicomErrorMalformed = 3,     // impossible lengths / nesting
    BKDicomErrorUnsupported = 4,   // valid DICOM the reader cannot decode (message says what)
    BKDicomErrorNoMemory = 5,
    BKDicomErrorNeedsInflate = 6,  // deflated dataset: inflate from info->datasetOffset, then BKDicomParseDataset
} BKDicomStatus;

#define BK_DICOM_MESSAGE 256

// What: reads a whole DICOM file held in memory. Fills `info` (call BKDicomInfoFree afterwards, also
// after an error). `stopAtPixelData` = 1 stops after locating the pixel data (fast header scan for the
// library list; fragment lists are still found). `message` (BK_DICOM_MESSAGE bytes, may be NULL)
// receives a plain-language reason on failure.
BKDicomStatus BKDicomParseFile(const uint8_t *data, size_t size, BKDicomInfo *info, char *message);

// What: reads a dataset (no preamble, no file meta) encoded with `syntax` - for the inflated contents of
// a deflated file. The info's file-meta fields (transfer syntax UID) are kept.
BKDicomStatus BKDicomParseDataset(const uint8_t *data, size_t size, BKDicomSyntax syntax, BKDicomInfo *info,
                                  char *message);

// What: frees the arrays inside `info` (not `info` itself) and zeroes them.
void BKDicomInfoFree(BKDicomInfo *info);

// What: 1 when the file holds an image this reader can turn into pixel values (with the glue's
// decoders for JPEG / JPEG 2000); otherwise 0 and a plain-language reason in `message`.
int BKDicomCanDecode(const BKDicomInfo *info, char *message);

// ---- Pixel values ----------------------------------------------------------------------------------

// What: bytes of one native (uncompressed) frame.
size_t BKDicomNativeFrameBytes(const BKDicomInfo *info);

// What: turns one frame of STORED pixels (the raw sample layout of the file: bitsAllocated per sample,
// samplesPerPixel samples, planarConfiguration, file endianness given by `bigEndian`) into modality
// values (stored value masked to bitsStored, sign-extended when signed, then * slope + intercept with
// the slope/intercept of `frame`). Colour (3 samples) becomes one luminance value per pixel
// (0.299 R + 0.587 G + 0.114 B; YBR_FULL uses its Y sample directly). `out` = rows * columns floats.
// Returns 0 on bad input.
// `swapOW8`: big endian files store 8-bit pixels in OW with each byte pair swapped; pass 1 to undo it.
int BKDicomStoredToValues(const BKDicomInfo *info, uint32_t frame, const uint8_t *stored, size_t storedBytes,
                          int bigEndian, int swapOW8, float *out);

// What: one native frame of the parsed buffer `data` into modality values (see above).
int BKDicomDecodeNativeFrame(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame,
                             float *out, char *message);

// What: the rescale slope and intercept for `frame` (per-frame values of enhanced files win).
void BKDicomFrameRescale(const BKDicomInfo *info, uint32_t frame, double *slope, double *intercept);

// What: position (3) and orientation (6) for `frame`; returns 1 when known. Per-frame values of
// enhanced files win; a classic multi-frame file without per-frame positions gets
// imagePosition + normal * spacingBetweenSlices (or sliceThickness) * frame.
int BKDicomFramePosition(const BKDicomInfo *info, uint32_t frame, double position[3]);
int BKDicomFrameOrientation(const BKDicomInfo *info, uint32_t frame, double orientation[6]);

// What: for encapsulated data, the fragment range [first, first + count) holding `frame`, using the basic
// offset table, one-fragment-per-frame, or (multi-fragment frames without a table) the frame start
// markers of JPEG (FFD8) / JPEG 2000 (FF4F) / RLE (one header per fragment). Returns 1 on success.
int BKDicomFrameFragments(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame,
                          uint32_t *first, uint32_t *count);

// What: the bytes of one encapsulated frame, its fragments joined (malloc'd; caller frees). NULL on error.
uint8_t *BKDicomCopyFrameBytes(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame,
                               size_t *length);

// ---- Small helpers shared with the glue and the tests -----------------------------------------------

// What: parses the n-th backslash-separated decimal number of a DS/IS string value (not NUL-terminated,
// `length` bytes). Returns 1 and the value on success.
int BKDicomParseNumber(const char *value, size_t length, int index, double *out);

#ifdef __cplusplus
}
#endif

#endif
