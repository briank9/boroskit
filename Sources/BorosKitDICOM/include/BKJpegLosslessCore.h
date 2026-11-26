// BorosKitDICOM: BKJpegLosslessCore - an original decoder for lossless JPEG (process 14, Huffman coded),
// the compression most CBCT machines use for DICOM export (transfer syntaxes 1.2.840.10008.1.2.4.57 and
// 1.2.840.10008.1.2.4.70 "SV1" = predictor 1).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 (<stdint.h>, <stddef.h>, <stdlib.h>, <string.h>); no Apple frameworks. Compiles unchanged on
//   Windows/Linux. CPU only (entropy decoding is serial by nature); frames are independent, so callers
//   decode many frames in parallel.
// - Written from the description of lossless JPEG in ITU-T T.81 (sections H.1 - H.2: predictors 1-7,
//   point transform, difference categories, the 16-bit "category 16" rule, restart intervals) and the
//   general marker / Huffman table layout. No code or tables were copied: lossless JPEG files carry their
//   own Huffman tables, so the decoder needs none of its own.
//
// Supported: precision 2..16 bits, 1..4 components with sampling factors 1x1, interleaved or separate
// scans, predictors 1-7, any point transform, restart markers. Not supported (clear error): arithmetic
// coding, hierarchical / differential frames, subsampled components, DNL-defined heights.

#ifndef BK_JPEG_LOSSLESS_CORE_H
#define BK_JPEG_LOSSLESS_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t width, height;
    uint32_t components;   // 1 (grey) or 3 (colour)
    uint32_t precision;    // bits per sample, 2..16
} BKJpegLosslessImage;

// What: reads only the frame header (size, components, precision). Returns 1 on success.
int BKJpegLosslessReadHeader(const uint8_t *data, size_t size, BKJpegLosslessImage *image, char *message);

// What: decodes the whole image into `out`: width * height * components samples of uint16_t, component-
// interleaved (R G B R G B ... for colour), row 0 first. `outCount` = number of uint16_t at out. Returns 1
// on success; on failure 0 and a plain-language reason in `message` (256 bytes, may be NULL).
// Values are the raw stored samples (point transform undone); signedness / rescale are the caller's.
int BKJpegLosslessDecode(const uint8_t *data, size_t size, uint16_t *out, size_t outCount,
                         BKJpegLosslessImage *image, char *message);

#ifdef __cplusplus
}
#endif

#endif
