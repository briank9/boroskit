// BorosKitCore: BKTiffCore - see BKTiffCore.h.
// Original BorosKit code written for this project; contains no third-party code (written from the TIFF 6.0
// specification, the BigTIFF layout and TIFF Technical Note 3).
// Boros 6 (2026-11-24, vtk-data).

#include "BKTiffCore.h"
#include <stdlib.h>
#include <string.h>

// ---- reading numbers in the file's byte order -----------------------------------------------------------------

static uint64_t BKTiffGet(const BKTiff *t, uint64_t off, int bytes)
{
    uint64_t v = 0;
    const uint8_t *p = t->data + off;
    if (t->bigEndian) for (int i = 0; i < bytes; i++) v = (v << 8) | p[i];
    else for (int i = bytes - 1; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static int BKTiffHostIsBigEndian(void) { const uint16_t one = 1; return *(const uint8_t *)&one == 0; }

// Size in bytes of one value of each field type (0 = unknown type).
static int BKTiffTypeSize(uint16_t type)
{
    switch (type)
    {
        case 1: case 2: case 6: case 7: return 1;      // BYTE, ASCII, SBYTE, UNDEFINED
        case 3: case 8: return 2;                      // SHORT, SSHORT
        case 4: case 9: case 11: case 13: return 4;    // LONG, SLONG, FLOAT, IFD
        case 5: case 10: case 12: return 8;            // RATIONAL, SRATIONAL, DOUBLE
        case 16: case 17: case 18: return 8;           // BigTIFF LONG8, SLONG8, IFD8
        default: return 0;
    }
}

// Layout of a directory: classic = 2-byte entry count, 12-byte entries, 4-byte next offset;
// BigTIFF = 8-byte count, 20-byte entries, 8-byte next offset.
static int BKTiffCountBytes(const BKTiff *t) { return t->bigTiff ? 8 : 2; }
static int BKTiffEntryBytes(const BKTiff *t) { return t->bigTiff ? 20 : 12; }
static int BKTiffOffsetBytes(const BKTiff *t) { return t->bigTiff ? 8 : 4; }

// The directory at `off` is complete inside the file? Then its entry count, else -1.
static int64_t BKTiffDirEntries(const BKTiff *t, uint64_t off)
{
    if (off == 0 || off > t->size || t->size - off < (uint64_t)BKTiffCountBytes(t)) return -1;
    uint64_t n = BKTiffGet(t, off, BKTiffCountBytes(t));
    uint64_t need = (uint64_t)BKTiffCountBytes(t) + n * (uint64_t)BKTiffEntryBytes(t) + (uint64_t)BKTiffOffsetBytes(t);
    if (n > 1000000 || t->size - off < need) return -1;
    return (int64_t)n;
}

// The next directory after the one at `off` (0 = none / broken).
static uint64_t BKTiffNextDir(const BKTiff *t, uint64_t off)
{
    int64_t n = BKTiffDirEntries(t, off);
    if (n < 0) return 0;
    uint64_t nx = BKTiffGet(t, off + BKTiffCountBytes(t) + (uint64_t)n * BKTiffEntryBytes(t), BKTiffOffsetBytes(t));
    return BKTiffDirEntries(t, nx) < 0 ? 0 : nx;
}

int BKTiffOpen(const uint8_t *data, size_t size, BKTiff *tif)
{
    if (tif == NULL) return BK_TIFF_ERROR;
    memset(tif, 0, sizeof(*tif));
    if (data == NULL || size < 8) return BK_TIFF_ERROR;
    BKTiff t = { data, size, 0, 0, 0, NULL };
    if (data[0] == 'I' && data[1] == 'I') t.bigEndian = 0;
    else if (data[0] == 'M' && data[1] == 'M') t.bigEndian = 1;
    else return BK_TIFF_ERROR;
    uint64_t version = BKTiffGet(&t, 2, 2), first;
    if (version == 42) first = BKTiffGet(&t, 4, 4);
    else if (version == 43)
    {
        if (size < 16 || BKTiffGet(&t, 4, 2) != 8 || BKTiffGet(&t, 6, 2) != 0) return BK_TIFF_ERROR;
        t.bigTiff = 1;
        first = BKTiffGet(&t, 8, 8);
    }
    else return BK_TIFF_ERROR;
    if (BKTiffDirEntries(&t, first) < 0) return BK_TIFF_ERROR;

    // Count the pages. A broken file may link back to an earlier page (a loop): find where the loop starts (mu)
    // and its length (lambda) with the "tortoise and hare" method, so every page is listed once.
    uint64_t slow = first, fast = first;
    int loop = 0;
    for (;;)
    {
        slow = BKTiffNextDir(&t, slow);
        fast = BKTiffNextDir(&t, fast); if (fast) fast = BKTiffNextDir(&t, fast);
        if (slow == 0 || fast == 0) break;
        if (slow == fast) { loop = 1; break; }
    }
    uint64_t pages = 0;
    if (loop)
    {
        uint64_t mu = 0, lambda = 1;
        slow = first;
        while (slow != fast) { slow = BKTiffNextDir(&t, slow); fast = BKTiffNextDir(&t, fast); mu++; }
        fast = BKTiffNextDir(&t, slow);
        while (fast != slow) { fast = BKTiffNextDir(&t, fast); lambda++; }
        pages = mu + lambda;
    }
    else for (uint64_t off = first; off; off = BKTiffNextDir(&t, off)) pages++;
    if (pages > 0x7fffffff) return BK_TIFF_ERROR;

    t.pageOffsets = (uint64_t *)malloc((size_t)pages * sizeof(uint64_t));
    if (t.pageOffsets == NULL) return BK_TIFF_ERROR;
    uint64_t off = first;
    for (uint64_t i = 0; i < pages; i++) { t.pageOffsets[i] = off; off = BKTiffNextDir(&t, off); }
    t.pageCount = (int)pages;
    *tif = t;
    return BK_TIFF_OK;
}

void BKTiffClose(BKTiff *tif)
{
    if (tif == NULL) return;
    free(tif->pageOffsets);
    memset(tif, 0, sizeof(*tif));
}

// ---- tags --------------------------------------------------------------------------------------------------------

typedef struct { uint16_t type; uint64_t count; uint64_t valueOff; } BKTiffEntry;

static int BKTiffEntryFind(const BKTiff *t, int page, uint16_t tag, BKTiffEntry *e)
{
    if (t == NULL || page < 0 || page >= t->pageCount) return 0;
    uint64_t dir = t->pageOffsets[page];
    int64_t n = BKTiffDirEntries(t, dir);
    for (int64_t i = 0; i < n; i++)
    {
        uint64_t p = dir + BKTiffCountBytes(t) + (uint64_t)i * BKTiffEntryBytes(t);
        if (BKTiffGet(t, p, 2) != tag) continue;
        e->type = (uint16_t)BKTiffGet(t, p + 2, 2);
        e->count = BKTiffGet(t, p + 4, BKTiffOffsetBytes(t));
        int size = BKTiffTypeSize(e->type);
        if (size == 0) return 0;
        uint64_t valueField = p + 4 + BKTiffOffsetBytes(t);
        if (e->count > (uint64_t)-1 / 16) return 0;
        uint64_t bytes = e->count * (uint64_t)size;
        // Small values sit in the entry itself, larger ones at the offset stored there.
        e->valueOff = bytes <= (uint64_t)BKTiffOffsetBytes(t) ? valueField : BKTiffGet(t, valueField, BKTiffOffsetBytes(t));
        if (e->valueOff > t->size || t->size - e->valueOff < bytes) return 0;
        return 1;
    }
    return 0;
}

// Value k of an integer-typed entry.
static uint64_t BKTiffEntryUInt(const BKTiff *t, const BKTiffEntry *e, uint64_t k)
{
    int size = BKTiffTypeSize(e->type);
    if (k >= e->count || size == 0 || e->type == 5 || e->type == 10 || e->type == 11 || e->type == 12) return 0;
    return BKTiffGet(t, e->valueOff + k * (uint64_t)size, size);
}

int BKTiffFindTag(const BKTiff *tif, int page, uint16_t tag, uint16_t *type, uint64_t *count, const uint8_t **bytes)
{
    BKTiffEntry e;
    if (!BKTiffEntryFind(tif, page, tag, &e)) return 0;
    if (type) *type = e.type;
    if (count) *count = e.count;
    if (bytes) *bytes = tif->data + e.valueOff;
    return 1;
}

uint64_t BKTiffTagUInt(const BKTiff *tif, int page, uint16_t tag, uint64_t fallback)
{
    BKTiffEntry e;
    if (!BKTiffEntryFind(tif, page, tag, &e) || e.count == 0) return fallback;
    return BKTiffEntryUInt(tif, &e, 0);
}

int BKTiffGetPage(const BKTiff *tif, int page, BKTiffPage *out)
{
    if (out == NULL) return BK_TIFF_ERROR;
    memset(out, 0, sizeof(*out));
    if (tif == NULL || page < 0 || page >= tif->pageCount) return BK_TIFF_ERROR;
    out->width = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_IMAGE_WIDTH, 0);
    out->height = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_IMAGE_LENGTH, 0);
    out->bitsPerSample = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_BITS_PER_SAMPLE, 1);
    out->samplesPerPixel = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_SAMPLES_PER_PIXEL, 1);
    out->sampleFormat = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_SAMPLE_FORMAT, BK_TIFF_SAMPLE_UINT);
    out->planarConfig = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_PLANAR_CONFIG, 1);
    out->compression = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_COMPRESSION, 1);
    out->predictor = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_PREDICTOR, 1);
    out->photometric = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_PHOTOMETRIC, 0xffffffffu);
    BKTiffEntry e;
    out->tiled = BKTiffEntryFind(tif, page, BK_TIFF_TAG_TILE_OFFSETS, &e) ? 1 : 0;
    uint64_t rps = BKTiffTagUInt(tif, page, BK_TIFF_TAG_ROWS_PER_STRIP, 0xffffffffu);
    out->rowsPerStrip = (rps == 0 || rps > out->height) ? out->height : (uint32_t)rps;
    out->tileWidth = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_TILE_WIDTH, 0);
    out->tileLength = (uint32_t)BKTiffTagUInt(tif, page, BK_TIFF_TAG_TILE_LENGTH, 0);
    if (out->samplesPerPixel == 0) out->samplesPerPixel = 1;
    if (out->planarConfig != 2) out->planarConfig = 1;
    return BK_TIFF_OK;
}

// Bytes in one packed row of `width` pixels with `samples` samples each.
static size_t BKTiffRowBytes(uint64_t width, uint64_t samples, uint64_t bits)
{
    uint64_t b = width * samples * bits;
    if (width && b / width / (samples ? samples : 1) != bits) return 0;   // overflow
    return (size_t)((b + 7) / 8);
}

size_t BKTiffPageBytes(const BKTiffPage *p)
{
    if (p == NULL || p->width == 0 || p->height == 0 || p->bitsPerSample == 0 || p->bitsPerSample > 64) return 0;
    uint64_t planes = p->planarConfig == 2 ? p->samplesPerPixel : 1;
    uint64_t perPlane = p->planarConfig == 2 ? 1 : p->samplesPerPixel;
    size_t row = BKTiffRowBytes(p->width, perPlane, p->bitsPerSample);
    if (row == 0) return 0;
    uint64_t total = (uint64_t)row * p->height * planes;
    if (total / planes / p->height != row || total > (uint64_t)SIZE_MAX / 2) return 0;
    return (size_t)total;
}

// ---- decompression --------------------------------------------------------------------------------------------

long BKTiffUnpackBits(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen)
{
    // PackBits (TIFF 6.0 section 9): a signed header byte n; 0..127 -> copy the next n+1 bytes literally,
    // -1..-127 -> repeat the next byte 1-n times, -128 -> nothing.
    size_t i = 0, o = 0;
    while (i < srcLen && o < dstLen)
    {
        int n = (int8_t)src[i++];
        if (n >= 0)
        {
            size_t c = (size_t)n + 1;
            if (i + c > srcLen) c = srcLen - i;
            if (o + c > dstLen) c = dstLen - o;
            memcpy(dst + o, src + i, c);
            i += (size_t)n + 1; o += c;
        }
        else if (n != -128)
        {
            if (i >= srcLen) break;
            size_t c = (size_t)(1 - n);
            if (o + c > dstLen) c = dstLen - o;
            memset(dst + o, src[i++], c);
            o += c;
        }
    }
    return (long)o;
}

long BKTiffDecodeLZW(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen)
{
    // TIFF LZW (TIFF 6.0 section 13): codes of 9..12 bits, most significant bit first; 256 = clear the table,
    // 257 = end; the code width grows one code early (when the table holds 511, 1023, 2047 strings).
    enum { CLEAR = 256, END = 257, FIRST = 258, MAXCODES = 4096 };
    uint16_t prefix[MAXCODES];
    uint8_t suffix[MAXCODES], firstByte[MAXCODES];
    uint32_t length[MAXCODES];
    for (int c = 0; c < 256; c++) { prefix[c] = 0xffff; suffix[c] = (uint8_t)c; firstByte[c] = (uint8_t)c; length[c] = 1; }
    int next = FIRST, width = 9, old = -1;
    uint64_t bitPos = 0, totalBits = (uint64_t)srcLen * 8;
    size_t o = 0;
    for (;;)
    {
        if (bitPos + (uint64_t)width > totalBits) break;             // data ended without an end code
        uint32_t code = 0;
        for (int b = 0; b < width; b++, bitPos++)
            code = (code << 1) | ((src[bitPos >> 3] >> (7 - (bitPos & 7))) & 1u);
        if (code == END) break;
        if (code == CLEAR) { next = FIRST; width = 9; old = -1; continue; }
        if (old < 0)
        {
            if (code > 255) return -1;                                // a string must start with a plain byte
            if (o < dstLen) dst[o++] = (uint8_t)code;
            old = (int)code;
            continue;
        }
        int known = (int)code < next;
        if (!known && (int)code != next) return -1;                    // broken data
        // The string to write: the code's own, or (not yet in the table) the previous one + its first byte.
        int str = known ? (int)code : old;
        uint32_t len = length[str] + (known ? 0 : 1);
        uint8_t first = firstByte[str];
        if (o + len <= dstLen)
        {
            size_t end = o + length[str];
            if (!known) dst[o + len - 1] = first;
            for (int c = str; c != 0xffff; c = prefix[c]) dst[--end] = suffix[c];
        }
        else
        {
            // Not enough room: write what fits (the rest of the block is cut off).
            uint8_t tmp[MAXCODES + 1];
            size_t end = length[str];
            for (int c = str; c != 0xffff; c = prefix[c]) tmp[--end] = suffix[c];
            if (!known) tmp[len - 1] = first;
            for (uint32_t k = 0; k < len && o + k < dstLen; k++) dst[o + k] = tmp[k];
            o = dstLen;
            break;
        }
        o += len;
        // New table entry: previous string + first byte of the current one.
        if (next < MAXCODES)
        {
            prefix[next] = (uint16_t)old;
            suffix[next] = known ? firstByte[code] : first;
            firstByte[next] = firstByte[old];
            length[next] = length[old] + 1;
            next++;
            if (next == 511) width = 10; else if (next == 1023) width = 11; else if (next == 2047) width = 12;
        }
        old = (int)code;
    }
    return (long)o;
}

// ---- page decoding ---------------------------------------------------------------------------------------------

static void BKTiffSwapSamples(uint8_t *p, size_t bytes, int sampleBytes)
{
    for (size_t i = 0; i + (size_t)sampleBytes <= bytes; i += (size_t)sampleBytes)
        for (int a = 0, b = sampleBytes - 1; a < b; a++, b--) { uint8_t t = p[i + a]; p[i + a] = p[i + b]; p[i + b] = t; }
}

// Undo the horizontal predictor (2) on one row of `count` pixels x `spp` samples, host byte order.
static void BKTiffUndoPredictor2(uint8_t *row, size_t count, uint32_t spp, uint32_t bits)
{
    size_t n = count * spp;
    switch (bits)
    {
        case 8:  for (size_t i = spp; i < n; i++) row[i] = (uint8_t)(row[i] + row[i - spp]); break;
        case 16: { uint16_t *s = (uint16_t *)row; for (size_t i = spp; i < n; i++) s[i] = (uint16_t)(s[i] + s[i - spp]); } break;
        case 32: { uint32_t *s = (uint32_t *)row; for (size_t i = spp; i < n; i++) s[i] = s[i] + s[i - spp]; } break;
        case 64: { uint64_t *s = (uint64_t *)row; for (size_t i = spp; i < n; i++) s[i] = s[i] + s[i - spp]; } break;
    }
}

// Undo the floating-point predictor (3, TIFF Technical Note 3) on one row: the bytes were split into planes
// (most significant first) and differenced with a stride of `spp`. Result: samples in host byte order.
static int BKTiffUndoPredictor3(uint8_t *row, size_t count, uint32_t spp, uint32_t bits)
{
    size_t wc = count * spp, bytes = bits / 8, total = wc * bytes;
    for (size_t i = spp; i < total; i++) row[i] = (uint8_t)(row[i] + row[i - spp]);
    uint8_t *tmp = (uint8_t *)malloc(total);
    if (tmp == NULL) return -1;
    memcpy(tmp, row, total);
    int hostBig = BKTiffHostIsBigEndian();
    for (size_t i = 0; i < wc; i++)
        for (size_t b = 0; b < bytes; b++)   // b = 0: most significant byte
            row[i * bytes + (hostBig ? b : bytes - 1 - b)] = tmp[b * wc + i];
    free(tmp);
    return 0;
}

// Decodes one strip / tile (compressed bytes src) into out[outLen]; returns 0, or BK_TIFF_ERROR/UNSUPPORTED.
static int BKTiffDecodeBlock(const BKTiffPage *p, const uint8_t *src, size_t srcLen, uint8_t *out, size_t outLen,
                             BKTiffInflateFn inflate, void *user)
{
    long got;
    switch (p->compression)
    {
        case 1: got = (long)(srcLen < outLen ? srcLen : outLen); memcpy(out, src, (size_t)got); break;
        case 32773: got = BKTiffUnpackBits(src, srcLen, out, outLen); break;
        case 5: got = BKTiffDecodeLZW(src, srcLen, out, outLen); break;
        case 8: case 32946:
            if (inflate == NULL) return BK_TIFF_UNSUPPORTED;
            got = inflate(src, srcLen, out, outLen, user);
            break;
        default: return BK_TIFF_UNSUPPORTED;
    }
    return got < 0 ? BK_TIFF_ERROR : BK_TIFF_OK;   // short blocks keep zeros at the end (like a short read)
}

// Byte order + predictor for `rows` rows of `rowPixels` pixels in buf (one block, already decompressed).
static int BKTiffFixRows(const BKTiff *t, const BKTiffPage *p, uint8_t *buf, size_t rows, size_t rowPixels, uint32_t spp)
{
    size_t rowBytes = BKTiffRowBytes(rowPixels, spp, p->bitsPerSample);
    int sampleBytes = (int)(p->bitsPerSample / 8);
    if (p->predictor == 3)
    {
        if (p->bitsPerSample % 8) return BK_TIFF_UNSUPPORTED;
        for (size_t r = 0; r < rows; r++) if (BKTiffUndoPredictor3(buf + r * rowBytes, rowPixels, spp, p->bitsPerSample)) return BK_TIFF_ERROR;
        return BK_TIFF_OK;
    }
    if (sampleBytes > 1 && p->bitsPerSample % 8 == 0 && t->bigEndian != BKTiffHostIsBigEndian())
        BKTiffSwapSamples(buf, rows * rowBytes, sampleBytes);
    if (p->predictor == 2)
    {
        if (p->bitsPerSample != 8 && p->bitsPerSample != 16 && p->bitsPerSample != 32 && p->bitsPerSample != 64) return BK_TIFF_UNSUPPORTED;
        for (size_t r = 0; r < rows; r++) BKTiffUndoPredictor2(buf + r * rowBytes, rowPixels, spp, p->bitsPerSample);
    }
    return BK_TIFF_OK;
}

int BKTiffReadPage(const BKTiff *tif, int page, void *dst, size_t dstSize, BKTiffInflateFn inflate, void *user)
{
    BKTiffPage p;
    if (BKTiffGetPage(tif, page, &p) != BK_TIFF_OK || dst == NULL) return BK_TIFF_ERROR;
    size_t pageBytes = BKTiffPageBytes(&p);
    if (pageBytes == 0 || dstSize < pageBytes) return BK_TIFF_ERROR;
    memset(dst, 0, pageBytes);
    if (p.predictor != 1 && p.predictor != 2 && p.predictor != 3) return BK_TIFF_UNSUPPORTED;
    uint32_t planes = p.planarConfig == 2 ? p.samplesPerPixel : 1;
    uint32_t spp = p.planarConfig == 2 ? 1 : p.samplesPerPixel;
    size_t rowBytes = BKTiffRowBytes(p.width, spp, p.bitsPerSample);
    size_t planeBytes = rowBytes * p.height;
    uint8_t *out = (uint8_t *)dst;

    BKTiffEntry offs, counts;
    if (!BKTiffEntryFind(tif, page, p.tiled ? BK_TIFF_TAG_TILE_OFFSETS : BK_TIFF_TAG_STRIP_OFFSETS, &offs)) return BK_TIFF_ERROR;
    int haveCounts = BKTiffEntryFind(tif, page, p.tiled ? BK_TIFF_TAG_TILE_BYTE_COUNTS : BK_TIFF_TAG_STRIP_BYTE_COUNTS, &counts);
    if (!haveCounts && p.compression != 1) return BK_TIFF_ERROR;

    if (!p.tiled)
    {
        uint64_t perPlane = ((uint64_t)p.height + p.rowsPerStrip - 1) / p.rowsPerStrip;
        for (uint32_t pl = 0; pl < planes; pl++)
            for (uint64_t s = 0; s < perPlane; s++)
            {
                uint64_t idx = (uint64_t)pl * perPlane + s;
                if (idx >= offs.count) return BK_TIFF_OK;                 // fewer strips than rows: rest stays 0
                uint64_t off = BKTiffEntryUInt(tif, &offs, idx);
                uint64_t row0 = s * p.rowsPerStrip;
                size_t rows = (size_t)((row0 + p.rowsPerStrip > p.height) ? p.height - row0 : p.rowsPerStrip);
                size_t want = rows * rowBytes;
                uint64_t len = haveCounts ? BKTiffEntryUInt(tif, &counts, idx) : want;
                if (off > tif->size) continue;
                if (len > tif->size - off) len = tif->size - off;          // cut at the end of the file
                uint8_t *block = out + (size_t)pl * planeBytes + (size_t)row0 * rowBytes;
                int r = BKTiffDecodeBlock(&p, tif->data + off, (size_t)len, block, want, inflate, user);
                if (r != BK_TIFF_OK) return r;
                r = BKTiffFixRows(tif, &p, block, rows, p.width, spp);
                if (r != BK_TIFF_OK) return r;
            }
        return BK_TIFF_OK;
    }

    // Tiles: each is tileWidth x tileLength pixels (edge tiles padded); decode, then copy the visible part.
    if (p.tileWidth == 0 || p.tileLength == 0 || p.bitsPerSample % 8) return BK_TIFF_UNSUPPORTED;
    size_t tileRow = BKTiffRowBytes(p.tileWidth, spp, p.bitsPerSample);
    size_t tileBytes = tileRow * p.tileLength;
    uint8_t *tile = (uint8_t *)malloc(tileBytes ? tileBytes : 1);
    if (tile == NULL) return BK_TIFF_ERROR;
    uint64_t across = ((uint64_t)p.width + p.tileWidth - 1) / p.tileWidth;
    uint64_t down = ((uint64_t)p.height + p.tileLength - 1) / p.tileLength;
    size_t pixelBytes = (size_t)spp * p.bitsPerSample / 8;
    int result = BK_TIFF_OK;
    for (uint32_t pl = 0; pl < planes && result == BK_TIFF_OK; pl++)
        for (uint64_t ty = 0; ty < down && result == BK_TIFF_OK; ty++)
            for (uint64_t tx = 0; tx < across; tx++)
            {
                uint64_t idx = ((uint64_t)pl * down + ty) * across + tx;
                if (idx >= offs.count) break;
                uint64_t off = BKTiffEntryUInt(tif, &offs, idx);
                uint64_t len = haveCounts ? BKTiffEntryUInt(tif, &counts, idx) : tileBytes;
                if (off > tif->size) continue;
                if (len > tif->size - off) len = tif->size - off;
                memset(tile, 0, tileBytes);
                result = BKTiffDecodeBlock(&p, tif->data + off, (size_t)len, tile, tileBytes, inflate, user);
                if (result == BK_TIFF_OK) result = BKTiffFixRows(tif, &p, tile, p.tileLength, p.tileWidth, spp);
                if (result != BK_TIFF_OK) break;
                uint64_t x0 = tx * p.tileWidth, y0 = ty * p.tileLength;
                size_t cols = (size_t)((x0 + p.tileWidth > p.width) ? p.width - x0 : p.tileWidth);
                for (uint32_t r = 0; r < p.tileLength && y0 + r < p.height; r++)
                    memcpy(out + (size_t)pl * planeBytes + (size_t)(y0 + r) * rowBytes + (size_t)x0 * pixelBytes,
                           tile + (size_t)r * tileRow, cols * pixelBytes);
            }
    free(tile);
    return result;
}
