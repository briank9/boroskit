// BorosKit Vulkan tests: BKPNGWrite - writes an RGBA8 picture as a PNG file (for people to look at).
// Original BorosKit code written for this project; contains no third-party code (written from the PNG and
// zlib format descriptions: chunks with CRC-32, zlib stream with uncompressed "stored" deflate blocks and
// Adler-32; the CRC table is computed at run time from the polynomial, not copied).
// Written 2026-11-26 by agent "vulkan-engine" (step M10). Plain C99. No compression (files are small).

#ifndef BK_PNG_WRITE_H
#define BK_PNG_WRITE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What: writes width x height RGBA8 pixels (row 0 = top) to `path`. Returns 0 on success.
int bk_png_write_rgba8(const char *path, const uint8_t *rgba, uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

#endif
