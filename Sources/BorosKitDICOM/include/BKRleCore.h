// BorosKitDICOM: BKRleCore - an original decoder for DICOM "RLE Lossless" (1.2.840.10008.1.2.5).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 (<stdint.h>, <stddef.h>, <string.h>); no Apple frameworks; CPU only; frames independent.
// - Written from the description of the RLE format in the DICOM standard (PS3.5 Annex G): a 64-byte header
//   (segment count + up to 15 segment offsets, little endian), then one byte-run segment per byte plane,
//   most significant byte first, for each sample in turn.
//
// Plain language: every pixel value is split into its bytes; all "high" bytes of the image form one stream,
// all "low" bytes another (and one stream per colour for RGB). Each stream is stored with simple run-length
// coding: "copy the next n bytes" or "repeat the next byte n times".

#ifndef BK_RLE_CORE_H
#define BK_RLE_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: decodes one RLE frame of `pixels` pixels with `samples` samples of `bytesPerSample` bytes into
// `out` (pixels * samples * bytesPerSample bytes), sample-interleaved, each sample LITTLE endian (so the
// result reads like native little-endian pixel data with planar configuration 0). Returns 1 on success,
// 0 and a plain-language message (256 bytes, may be NULL) on failure.
int BKRleDecodeFrame(const uint8_t *data, size_t size, size_t pixels, uint32_t samples, uint32_t bytesPerSample,
                     uint8_t *out, char *message);

#ifdef __cplusplus
}
#endif

#endif
