// BorosKitDICOM: BKZipCore - an original reader for the table of contents of ZIP archives (the folder of DICOM
// files a user zips, or a Boros 6 ".borosdicom" package), in plain C99.
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES (Vulkan / other backends, Windows / Linux):
// - Pure C99 (<stdint.h>, <stddef.h>, <stdlib.h>, <string.h>); no Apple frameworks. Compiles unchanged on
//   Windows/Linux. The DEFLATE decompression of the entries is NOT here: the Apple glue (BKZipArchive.m) uses
//   Apple's Compression framework (raw DEFLATE); a Windows/Linux build plugs in its platform's inflater.
// - Written from the published description of the ZIP file layout (end-of-central-directory record, central
//   directory headers, local headers, Zip64 records and extra field, general-purpose flags). The CRC-32 table
//   is generated at run time from the CRC polynomial, not copied.
//
// Plain language: a ZIP file ends with a table of contents listing every file inside: its name, how it is
// packed (stored as-is or "deflated") and where its bytes are. This reads that table safely (every offset
// is checked) and refuses names that would escape the target folder ("../", absolute paths).

#ifndef BK_ZIP_CORE_H
#define BK_ZIP_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *name;                 // as stored (UTF-8 or the old DOS code page), NUL-terminated (malloc'd)
    uint64_t compressedSize;
    uint64_t uncompressedSize;
    uint64_t dataOffset;        // first byte of the packed data (after the local header)
    uint32_t crc32;
    int32_t method;             // 0 = stored, 8 = deflate, others unsupported
    int32_t isDirectory;
    int32_t encrypted;
} BKZipEntry;

// What: reads the table of contents of the archive held in memory. On success returns 1 and a malloc'd array
// (free with BKZipFreeEntries). On failure 0 and a plain-language reason (256 bytes, may be NULL).
int BKZipReadEntries(const uint8_t *data, size_t size, BKZipEntry **entries, uint32_t *count, char *message);
void BKZipFreeEntries(BKZipEntry *entries, uint32_t count);

// What: the standard CRC-32 (as used by ZIP); pass 0 to start, then the previous result to continue.
uint32_t BKZipCRC32(uint32_t crc, const uint8_t *bytes, size_t length);

// What: a safe relative path for an entry name: backslashes become '/', "./" parts and empty parts are
// dropped; returns 0 for names that are absolute, contain "..", are empty, or are macOS resource-fork
// clutter ("__MACOSX/", "._name", ".DS_Store"). `out` gets the cleaned path.
int BKZipSafeRelativePath(const char *name, char *out, size_t outSize);

#ifdef __cplusplus
}
#endif

#endif
