// BorosKitDICOM: BKZipCore - see BKZipCore.h.
//
// Original BorosKit code written for this project; contains no third-party code.

#include "BKZipCore.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static uint16_t BKZ16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t BKZ32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t BKZ64(const uint8_t *p) { return (uint64_t)BKZ32(p) | ((uint64_t)BKZ32(p + 4) << 32); }

static void BKZMessage(char *message, const char *text) { if (message) snprintf(message, 256, "%s", text); }

void BKZipFreeEntries(BKZipEntry *entries, uint32_t count)
{
    if (!entries) return;
    for (uint32_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
}

int BKZipReadEntries(const uint8_t *data, size_t size, BKZipEntry **outEntries, uint32_t *outCount, char *message)
{
    *outEntries = NULL;
    *outCount = 0;
    if (!data || size < 22) { BKZMessage(message, "The file is too small to be a ZIP archive."); return 0; }
    // End of central directory: the last "PK\5\6" record, at most 65535 + 22 bytes from the end (comment).
    size_t eocd = (size_t)-1;
    size_t lowest = size > 65557 ? size - 65557 : 0;
    for (size_t p = size - 22 + 1; p-- > lowest;) {
        if (BKZ32(data + p) == 0x06054b50) { eocd = p; break; }
    }
    if (eocd == (size_t)-1) { BKZMessage(message, "Not a ZIP archive (no table of contents found)."); return 0; }
    uint64_t total = BKZ16(data + eocd + 10);
    uint64_t cdSize = BKZ32(data + eocd + 12);
    uint64_t cdOffset = BKZ32(data + eocd + 16);
    if (BKZ16(data + eocd + 4) != 0 || BKZ16(data + eocd + 6) != 0) { BKZMessage(message, "Split (multi-part) ZIP archives are not supported."); return 0; }
    // Zip64: a locator just before the record points to the 64-bit end record.
    if ((total == 0xFFFF || cdSize == 0xFFFFFFFFu || cdOffset == 0xFFFFFFFFu) && eocd >= 20 && BKZ32(data + eocd - 20) == 0x07064b50) {
        uint64_t z = BKZ64(data + eocd - 20 + 8);
        if (z > size - 56 || BKZ32(data + z) != 0x06064b50) { BKZMessage(message, "The ZIP archive's 64-bit table of contents is damaged."); return 0; }
        total = BKZ64(data + z + 32);
        cdSize = BKZ64(data + z + 40);
        cdOffset = BKZ64(data + z + 48);
    }
    if (cdOffset > size || cdSize > size - cdOffset) { BKZMessage(message, "The ZIP archive is incomplete (table of contents out of range)."); return 0; }
    if (total > 10000000) { BKZMessage(message, "The ZIP archive lists too many files."); return 0; }
    BKZipEntry *entries = (BKZipEntry *)calloc(total ? total : 1, sizeof(BKZipEntry));
    if (!entries) { BKZMessage(message, "Out of memory."); return 0; }
    size_t p = (size_t)cdOffset, end = (size_t)(cdOffset + cdSize);
    uint32_t n = 0;
    for (; n < total; n++) {
        if (p + 46 > end || BKZ32(data + p) != 0x02014b50) { BKZipFreeEntries(entries, n); BKZMessage(message, "The ZIP archive's table of contents is damaged."); return 0; }
        uint16_t flags = BKZ16(data + p + 8), method = BKZ16(data + p + 10);
        uint32_t crc = BKZ32(data + p + 16);
        uint64_t csize = BKZ32(data + p + 20), usize = BKZ32(data + p + 24);
        uint16_t nameLen = BKZ16(data + p + 28), extraLen = BKZ16(data + p + 30), commentLen = BKZ16(data + p + 32);
        uint64_t local = BKZ32(data + p + 42);
        if (p + 46 + (size_t)nameLen + extraLen + commentLen > end) { BKZipFreeEntries(entries, n); BKZMessage(message, "The ZIP archive's table of contents is damaged."); return 0; }
        // Zip64 extra field (id 1): the 64-bit values of whichever fields were set to all ones, in this order.
        const uint8_t *extra = data + p + 46 + nameLen;
        for (size_t e = 0; e + 4 <= extraLen;) {
            uint16_t id = BKZ16(extra + e), len = BKZ16(extra + e + 2);
            if (e + 4 + len > extraLen) break;
            if (id == 0x0001) {
                size_t q = e + 4, stop = e + 4 + len;
                if (usize == 0xFFFFFFFFu && q + 8 <= stop) { usize = BKZ64(extra + q); q += 8; }
                if (csize == 0xFFFFFFFFu && q + 8 <= stop) { csize = BKZ64(extra + q); q += 8; }
                if (local == 0xFFFFFFFFu && q + 8 <= stop) { local = BKZ64(extra + q); q += 8; }
            }
            e += 4 + len;
        }
        BKZipEntry *entry = &entries[n];
        entry->name = (char *)malloc((size_t)nameLen + 1);
        if (!entry->name) { BKZipFreeEntries(entries, n); BKZMessage(message, "Out of memory."); return 0; }
        memcpy(entry->name, data + p + 46, nameLen);
        entry->name[nameLen] = 0;
        entry->crc32 = crc;
        entry->method = method;
        entry->compressedSize = csize;
        entry->uncompressedSize = usize;
        entry->encrypted = (flags & 1) != 0;
        entry->isDirectory = nameLen > 0 && (entry->name[nameLen - 1] == '/' || entry->name[nameLen - 1] == '\\');
        // The data starts after the LOCAL header, whose name / extra lengths may differ from the central ones.
        if (local > size - 30 || BKZ32(data + local) != 0x04034b50) { BKZipFreeEntries(entries, n + 1); BKZMessage(message, "A file inside the ZIP archive is damaged (bad local header)."); return 0; }
        uint64_t dataOffset = local + 30 + BKZ16(data + local + 26) + BKZ16(data + local + 28);
        if (dataOffset > size || csize > size - dataOffset) { BKZipFreeEntries(entries, n + 1); BKZMessage(message, "The ZIP archive is incomplete (a file is cut short)."); return 0; }
        entry->dataOffset = dataOffset;
        p += 46 + (size_t)nameLen + extraLen + commentLen;
    }
    *outEntries = entries;
    *outCount = n;
    return 1;
}

uint32_t BKZipCRC32(uint32_t crc, const uint8_t *bytes, size_t length)
{
    // Table generated from the reflected CRC-32 polynomial 0xEDB88320 the first time (written out here, not
    // copied: entry i = i shifted out 8 times, xor-ing the polynomial whenever the low bit is set).
    static uint32_t table[256];
    static int ready = 0;
    if (!ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = 1;   // benign race: every thread writes identical values
    }
    crc = ~crc;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

int BKZipSafeRelativePath(const char *name, char *out, size_t outSize)
{
    if (!name || !out || outSize < 2) return 0;
    if (name[0] == '/' || name[0] == '\\' || (name[0] && name[1] == ':')) return 0;   // absolute / drive letter
    size_t o = 0;
    const char *p = name;
    while (*p) {
        const char *start = p;
        while (*p && *p != '/' && *p != '\\') p++;
        size_t len = (size_t)(p - start);
        if (*p) p++;
        if (len == 0 || (len == 1 && start[0] == '.')) continue;
        if (len == 2 && start[0] == '.' && start[1] == '.') return 0;
        if (len == 8 && memcmp(start, "__MACOSX", 8) == 0) return 0;
        if (len >= 2 && start[0] == '.' && start[1] == '_') return 0;   // AppleDouble "._name"
        if (len == 9 && memcmp(start, ".DS_Store", 9) == 0) return 0;
        if (o + len + 2 > outSize) return 0;
        if (o > 0) out[o++] = '/';
        memcpy(out + o, start, len);
        o += len;
    }
    out[o] = 0;
    return o > 0;
}
