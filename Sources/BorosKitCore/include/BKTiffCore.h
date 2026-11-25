// BorosKitCore: BKTiffCore - reading TIFF picture files (single and multi-page, 8 / 16 / 32-bit, integer or
// floating point, grey or colour) from memory. Plain C99.
// Boros 6 (2026-11-24, vtk-data): replaces the copy of libtiff that came bundled inside VTK (vtk_tiff.h) for
// DCMPix (TIFF / LSM / FluoView pictures), DicomFile (recognising TIFF files, page counts, FluoView headers) and
// FVTiff (FluoView meta-data).
//
// Original BorosKit code written for this project; contains no third-party code. Written from the public
// "TIFF Revision 6.0" specification (Adobe, 1992), the BigTIFF file layout, and Adobe's "TIFF Technical Note 3"
// (floating-point predictor). No libtiff code, tables or names were used.
//
// What it does:
// - checks the file header ("II" little-endian / "MM" big-endian; classic TIFF 42 and BigTIFF 43);
// - walks the chain of pages (image file directories), guarded against loops and broken offsets;
// - gives each page's basic description (size, bits per sample, samples per pixel, sample format, planar layout,
//   compression, predictor, strips or tiles) and any tag's raw bytes (used for the FluoView private tags);
// - decodes a page's samples, in the machine's own byte order, rows packed one after another (no padding),
//   colour samples interleaved (planar layout 1) or plane after plane (planar layout 2):
//   compression none (1), PackBits (32773) and LZW (5) are decoded here; Deflate (8 / 32946) through a
//   callback the caller supplies (on the Mac: Apple's libcompression - see PORTING NOTES); others (JPEG, CCITT,
//   ...) return BK_TIFF_UNSUPPORTED so the caller can try the system's image reader;
//   the horizontal predictor (2, integer samples of 8 / 16 / 32 / 64 bits) and the floating-point predictor
//   (3) are undone.
// The pixel values are NOT changed (no colour conversion, no "white is zero" inversion, no palette lookup):
// exactly the stored numbers, like reading a TIFF's scan lines.
//
// PORTING NOTES (Vulkan / other backends): VULKAN: safe to translate directly. CPU only, pure C99 (stdint, string,
// stdlib); no Apple or GPU types; deterministic. The file is passed in as memory (the Mac glue maps the file
// with NSData; Windows/Linux: mmap / MapViewOfFile or a read into memory). The Deflate callback must inflate a
// zlib stream (RFC 1950 header + deflate data + checksum): Windows/Linux can use their platform decompressor or
// an own inflater - BorosKit does not bundle zlib (no third-party code).
//
// Plain language: opens TIFF pictures (also stacks of many pictures in one file) without VTK.

#ifndef BK_TIFF_CORE_H
#define BK_TIFF_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    BK_TIFF_OK = 0,
    BK_TIFF_ERROR = -1,          // not a TIFF, broken file, bad arguments, out of memory
    BK_TIFF_UNSUPPORTED = -2     // valid page, but a compression / layout this reader does not decode
};

// TIFF tag numbers used by Boros (from the TIFF 6.0 specification).
enum {
    BK_TIFF_TAG_SUBFILE_TYPE = 254, BK_TIFF_TAG_IMAGE_WIDTH = 256, BK_TIFF_TAG_IMAGE_LENGTH = 257,
    BK_TIFF_TAG_BITS_PER_SAMPLE = 258, BK_TIFF_TAG_COMPRESSION = 259, BK_TIFF_TAG_PHOTOMETRIC = 262,
    BK_TIFF_TAG_IMAGE_DESCRIPTION = 270, BK_TIFF_TAG_STRIP_OFFSETS = 273, BK_TIFF_TAG_SAMPLES_PER_PIXEL = 277,
    BK_TIFF_TAG_ROWS_PER_STRIP = 278, BK_TIFF_TAG_STRIP_BYTE_COUNTS = 279, BK_TIFF_TAG_PLANAR_CONFIG = 284,
    BK_TIFF_TAG_PREDICTOR = 317, BK_TIFF_TAG_TILE_WIDTH = 322, BK_TIFF_TAG_TILE_LENGTH = 323,
    BK_TIFF_TAG_TILE_OFFSETS = 324, BK_TIFF_TAG_TILE_BYTE_COUNTS = 325, BK_TIFF_TAG_SAMPLE_FORMAT = 339
};

// Sample format values (tag 339): 1 unsigned integer (the default), 2 signed integer, 3 floating point.
enum { BK_TIFF_SAMPLE_UINT = 1, BK_TIFF_SAMPLE_INT = 2, BK_TIFF_SAMPLE_FLOAT = 3 };

typedef struct {
    const uint8_t *data;         // the whole file (owned by the caller; must stay valid while this is used)
    size_t size;
    int bigEndian;               // "MM" file
    int bigTiff;                 // BigTIFF (8-byte offsets)
    int pageCount;
    uint64_t *pageOffsets;       // file offset of each page's directory
} BKTiff;

typedef struct {
    uint32_t width, height;
    uint32_t bitsPerSample;      // of the first sample (Boros' callers expect all samples alike)
    uint32_t samplesPerPixel;
    uint32_t sampleFormat;       // BK_TIFF_SAMPLE_...
    uint32_t planarConfig;       // 1 = interleaved, 2 = plane after plane
    uint32_t compression, predictor, photometric;
    uint32_t tiled;              // 1 = tiles, 0 = strips
    uint32_t rowsPerStrip;       // strips: rows per strip (height when the tag is missing)
    uint32_t tileWidth, tileLength;
} BKTiffPage;

// What: reads the header and the page chain of a TIFF file held in memory. Returns BK_TIFF_OK (free with
// BKTiffClose) or BK_TIFF_ERROR (`tif` left empty, nothing to free).
int BKTiffOpen(const uint8_t *data, size_t size, BKTiff *tif);
void BKTiffClose(BKTiff *tif);

// What: page `page`'s description (defaults of the specification for missing tags). Returns BK_TIFF_OK / ERROR.
int BKTiffGetPage(const BKTiff *tif, int page, BKTiffPage *out);

// What: tag `tag` of page `page`: its field type (1 BYTE, 2 ASCII, 3 SHORT, 4 LONG, 7 UNDEFINED, ...), number of
// values and a pointer to its raw bytes inside the file (in the FILE's byte order). Returns 1 when present.
int BKTiffFindTag(const BKTiff *tif, int page, uint16_t tag, uint16_t *type, uint64_t *count, const uint8_t **bytes);

// What: the first value of an integer tag (BYTE / SHORT / LONG / LONG8 ...), or `fallback` when missing.
uint64_t BKTiffTagUInt(const BKTiff *tif, int page, uint16_t tag, uint64_t fallback);

// What: bytes BKTiffReadPage writes for this page (rows packed, all planes), 0 for an impossible page.
size_t BKTiffPageBytes(const BKTiffPage *page);

// What: inflates a zlib stream src[srcLen] into dst[dstLen]; returns the number of bytes written, or -1.
typedef long (*BKTiffInflateFn)(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen, void *user);

// What: decodes page `page` into dst (at least BKTiffPageBytes bytes; missing / short data stays 0).
// inflate may be NULL (then Deflate pages give BK_TIFF_UNSUPPORTED).
int BKTiffReadPage(const BKTiff *tif, int page, void *dst, size_t dstSize, BKTiffInflateFn inflate, void *user);

// Helpers exposed for the tests (and usable by other cores): PackBits / TIFF LZW decoding of one block.
// Return the number of bytes written to dst (at most dstLen), or -1 for broken data.
long BKTiffUnpackBits(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen);
long BKTiffDecodeLZW(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen);

#ifdef __cplusplus
}
#endif

#endif
