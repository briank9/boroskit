// BorosKitDICOM: BKJpegLosslessCore - see BKJpegLosslessCore.h.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written from the lossless-JPEG description in ITU-T T.81 (Annex H) and the marker layout in Annex B.

#include "BKJpegLosslessCore.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define BK_JL_MAX_COMPONENTS 4

static void BKJLMessage(char *message, const char *text)
{
    if (message) snprintf(message, 256, "%s", text);
}

// ---- Huffman tables ------------------------------------------------------------------------------

typedef struct {
    int defined;
    // Canonical code ranges per code length 1..16 (index 0 unused).
    int32_t minCode[17], maxCode[17], valueIndex[17];
    uint8_t values[256];
    // Fast path: the first 8 bits of the stream -> (length << 8 | value), 0 = longer than 8 bits.
    uint16_t fast[256];
} BKJLTable;

// What: builds the canonical codes from the 16 code-length counts and the symbol list (the JPEG layout:
// codes of each length are consecutive numbers, the first code of a length is (last code + 1) << 1).
static int BKJLBuildTable(BKJLTable *t, const uint8_t counts[16], const uint8_t *values, int total)
{
    memset(t, 0, sizeof(*t));
    if (total > 256) return 0;
    memcpy(t->values, values, (size_t)total);
    int32_t code = 0;
    int k = 0;
    for (int len = 1; len <= 16; len++) {
        int n = counts[len - 1];
        t->valueIndex[len] = k;
        t->minCode[len] = code;
        if (n == 0) {
            t->maxCode[len] = -1;
        } else {
            for (int i = 0; i < n; i++, k++, code++) {
                if (len <= 8) {
                    // Every 8-bit prefix that starts with this code maps to it.
                    int spare = 8 - len;
                    int start = code << spare;
                    for (int f = 0; f < (1 << spare); f++) t->fast[start + f] = (uint16_t)((len << 8) | values[k]);
                }
            }
            t->maxCode[len] = code - 1;
            if (code - 1 >= (1 << len)) return 0;   // more codes than this length can hold: corrupt table
        }
        code <<= 1;
    }
    t->defined = 1;
    return 1;
}

// ---- Bit reader (handles the 0xFF00 byte stuffing and stops at markers) ---------------------------

typedef struct {
    const uint8_t *data;
    size_t size, pos;
    uint32_t buffer;   // bits waiting, most significant first
    int bits;
    int atMarker;      // a marker was reached: further bits read as 0
} BKJLBits;

static void BKJLFill(BKJLBits *b)
{
    while (b->bits <= 24) {
        uint32_t byte = 0;
        if (!b->atMarker && b->pos < b->size) {
            byte = b->data[b->pos];
            if (byte == 0xFF) {
                uint8_t next = b->pos + 1 < b->size ? b->data[b->pos + 1] : 0xD9;
                if (next == 0x00) b->pos += 2;          // stuffed 0xFF data byte
                else { b->atMarker = 1; byte = 0; }      // a marker: leave it for the caller
            } else {
                b->pos++;
            }
        } else {
            b->atMarker = 1;
        }
        b->buffer |= byte << (24 - b->bits);
        b->bits += 8;
    }
}

static uint32_t BKJLGetBits(BKJLBits *b, int n)
{
    if (n == 0) return 0;
    if (b->bits < n) BKJLFill(b);
    uint32_t v = b->buffer >> (32 - n);
    b->buffer <<= n;
    b->bits -= n;
    return v;
}

// What: one Huffman-coded symbol; -1 when no code matches (corrupt data).
static int BKJLDecodeSymbol(BKJLBits *b, const BKJLTable *t)
{
    if (b->bits < 16) BKJLFill(b);
    uint16_t f = t->fast[b->buffer >> 24];
    if (f) {
        int len = f >> 8;
        b->buffer <<= len;
        b->bits -= len;
        return f & 0xFF;
    }
    int32_t code = 0;
    for (int len = 1; len <= 16; len++) {
        code = (code << 1) | (int32_t)((b->buffer >> (31 - (len - 1))) & 1);
        if (t->maxCode[len] >= 0 && code <= t->maxCode[len] && code >= t->minCode[len]) {
            b->buffer <<= len;
            b->bits -= len;
            return t->values[t->valueIndex[len] + code - t->minCode[len]];
        }
    }
    return -1;
}

// ---- Markers -------------------------------------------------------------------------------------

typedef struct {
    uint32_t width, height, precision, componentCount;
    uint8_t componentId[BK_JL_MAX_COMPONENTS];
    int frameSeen;
    BKJLTable tables[4];
    uint32_t restartInterval;
} BKJLState;

static uint32_t BKJLRead16(const uint8_t *p) { return ((uint32_t)p[0] << 8) | p[1]; }

// What: the next marker at or after `pos` (skips fill bytes); returns its code, or -1 at the end.
static int BKJLNextMarker(const uint8_t *data, size_t size, size_t *pos)
{
    size_t p = *pos;
    while (p + 1 < size) {
        if (data[p] == 0xFF) {
            uint8_t m = data[p + 1];
            if (m == 0xFF) { p++; continue; }                 // fill byte
            if (m != 0x00 && !(m >= 0xD0 && m <= 0xD7)) { *pos = p + 2; return m; }
            p += 2;                                           // stuffed byte or restart marker inside data
            continue;
        }
        p++;
    }
    return -1;
}

static int BKJLReadFrameHeader(BKJLState *s, const uint8_t *seg, uint32_t len, char *message)
{
    if (len < 6) { BKJLMessage(message, "Damaged JPEG frame header."); return 0; }
    s->precision = seg[0];
    s->height = BKJLRead16(seg + 1);
    s->width = BKJLRead16(seg + 3);
    s->componentCount = seg[5];
    if (s->precision < 2 || s->precision > 16) { BKJLMessage(message, "Unsupported lossless JPEG precision."); return 0; }
    if (s->width == 0) { BKJLMessage(message, "The JPEG image has no width."); return 0; }
    if (s->height == 0) { BKJLMessage(message, "JPEG images whose height is given at the end (DNL) are not supported."); return 0; }
    if (s->componentCount < 1 || s->componentCount > BK_JL_MAX_COMPONENTS || len < 6 + 3 * s->componentCount) {
        BKJLMessage(message, "Unsupported number of JPEG components.");
        return 0;
    }
    for (uint32_t c = 0; c < s->componentCount; c++) {
        s->componentId[c] = seg[6 + 3 * c];
        uint8_t sampling = seg[7 + 3 * c];
        if (sampling != 0x11) { BKJLMessage(message, "Subsampled lossless JPEG components are not supported."); return 0; }
    }
    s->frameSeen = 1;
    return 1;
}

static int BKJLReadTables(BKJLState *s, const uint8_t *seg, uint32_t len, char *message)
{
    uint32_t p = 0;
    while (p < len) {
        if (p + 17 > len) { BKJLMessage(message, "Damaged JPEG Huffman table."); return 0; }
        uint8_t classAndId = seg[p];
        const uint8_t *counts = seg + p + 1;
        int total = 0;
        for (int i = 0; i < 16; i++) total += counts[i];
        if (p + 17 + (uint32_t)total > len) { BKJLMessage(message, "Damaged JPEG Huffman table."); return 0; }
        int id = classAndId & 0x0F;
        if ((classAndId >> 4) == 0 && id < 4) {   // DC tables are the only ones lossless JPEG uses
            if (!BKJLBuildTable(&s->tables[id], counts, seg + p + 17, total)) { BKJLMessage(message, "Damaged JPEG Huffman table."); return 0; }
        }
        p += 17 + (uint32_t)total;
    }
    return 1;
}

static int32_t BKJLFloorHalf(int32_t x) { return (x - (x & 1)) / 2; }

// What: decodes one scan (its header in `seg`, the entropy data from `*pos`); writes samples into out.
static int BKJLDecodeScan(BKJLState *s, const uint8_t *seg, uint32_t len, const uint8_t *data, size_t size, size_t *pos,
                          uint16_t *out, char *message)
{
    if (!s->frameSeen) { BKJLMessage(message, "JPEG scan before the frame header."); return 0; }
    if (len < 1) { BKJLMessage(message, "Damaged JPEG scan header."); return 0; }
    uint32_t ns = seg[0];
    if (ns < 1 || ns > s->componentCount || len < 1 + 2 * ns + 3) { BKJLMessage(message, "Damaged JPEG scan header."); return 0; }
    int componentIndex[BK_JL_MAX_COMPONENTS];
    const BKJLTable *tables[BK_JL_MAX_COMPONENTS];
    for (uint32_t i = 0; i < ns; i++) {
        uint8_t id = seg[1 + 2 * i];
        int found = -1;
        for (uint32_t c = 0; c < s->componentCount; c++) if (s->componentId[c] == id) found = (int)c;
        int table = seg[2 + 2 * i] >> 4;
        if (found < 0 || table > 3 || !s->tables[table].defined) { BKJLMessage(message, "A JPEG scan refers to a missing component or table."); return 0; }
        componentIndex[i] = found;
        tables[i] = &s->tables[table];
    }
    int predictor = seg[1 + 2 * ns];
    int pointTransform = seg[3 + 2 * ns] & 0x0F;
    if (predictor < 1 || predictor > 7) { BKJLMessage(message, "Unsupported lossless JPEG predictor."); return 0; }
    if ((uint32_t)pointTransform >= s->precision) { BKJLMessage(message, "Invalid lossless JPEG point transform."); return 0; }

    const uint32_t W = s->width, H = s->height, NC = s->componentCount;
    const int32_t initial = 1 << (s->precision - pointTransform - 1);
    const uint32_t mask = 0xFFFF;   // arithmetic modulo 2^16 (T.81 H.1.2.1)

    // Samples are kept in the shifted domain while decoding; the point transform is applied at the end.
    BKJLBits bits = { data, size, *pos, 0, 0, 0 };
    uint32_t restartsLeft = s->restartInterval;
    int firstLine = 1, resetNext = 1;
    uint32_t mcus = 0;

    for (uint32_t y = 0; y < H; y++) {
        for (uint32_t x = 0; x < W; x++) {
            if (s->restartInterval && mcus > 0 && restartsLeft == 0) {
                // Restart marker: drop leftover bits, step over the RSTn marker, reset the predictors.
                size_t p = bits.pos;
                while (p + 1 < size && !(data[p] == 0xFF && data[p + 1] >= 0xD0 && data[p + 1] <= 0xD7)) p++;
                if (p + 1 >= size) { BKJLMessage(message, "A JPEG restart marker is missing."); return 0; }
                bits.pos = p + 2;
                bits.buffer = 0; bits.bits = 0; bits.atMarker = 0;
                restartsLeft = s->restartInterval;
                firstLine = 1; resetNext = 1;
            }
            for (uint32_t i = 0; i < ns; i++) {
                int c = componentIndex[i];
                int sym = BKJLDecodeSymbol(&bits, tables[i]);
                if (sym < 0 || sym > 16) { BKJLMessage(message, "Corrupt lossless JPEG data."); return 0; }
                int32_t diff;
                if (sym == 0) diff = 0;
                else if (sym == 16) diff = 32768;
                else {
                    int32_t v = (int32_t)BKJLGetBits(&bits, sym);
                    diff = (v < (1 << (sym - 1))) ? v - (1 << sym) + 1 : v;
                }
                // Neighbours: a = left, b = above, c = above-left (shifted-domain values).
                size_t here = ((size_t)y * W + x) * NC + (size_t)c;
                int32_t predicted;
                if (resetNext) predicted = initial;
                else if (firstLine) predicted = out[here - NC];
                else if (x == 0) predicted = out[here - (size_t)W * NC];
                else {
                    int32_t a = out[here - NC], b = out[here - (size_t)W * NC], cc = out[here - (size_t)W * NC - NC];
                    switch (predictor) {
                        case 1: predicted = a; break;
                        case 2: predicted = b; break;
                        case 3: predicted = cc; break;
                        case 4: predicted = a + b - cc; break;
                        case 5: predicted = a + BKJLFloorHalf(b - cc); break;
                        case 6: predicted = b + BKJLFloorHalf(a - cc); break;
                        default: predicted = BKJLFloorHalf(a + b); break;
                    }
                }
                out[here] = (uint16_t)((uint32_t)(predicted + diff) & mask);
            }
            resetNext = 0;
            mcus++;
            if (s->restartInterval) restartsLeft--;
        }
        firstLine = 0;
    }
    if (pointTransform) {
        for (uint32_t i = 0; i < ns; i++) {
            int c = componentIndex[i];
            for (size_t p = 0; p < (size_t)W * H; p++) out[p * NC + (size_t)c] = (uint16_t)(out[p * NC + (size_t)c] << pointTransform);
        }
    }
    *pos = bits.pos;
    return 1;
}

static int BKJLRun(const uint8_t *data, size_t size, uint16_t *out, size_t outCount, BKJpegLosslessImage *image,
                   char *message, int headerOnly)
{
    BKJLState *s = (BKJLState *)calloc(1, sizeof(BKJLState));
    if (!s) { BKJLMessage(message, "Out of memory."); return 0; }
    int ok = 0, scans = 0;
    size_t pos = 0;
    if (size < 4 || data[0] != 0xFF || data[1] != 0xD8) { BKJLMessage(message, "Not a JPEG stream (no start marker)."); goto done; }
    pos = 2;
    while (1) {
        int m = BKJLNextMarker(data, size, &pos);
        if (m < 0 || m == 0xD9) break;                         // end of image
        if (m == 0xD8 || m == 0x01) continue;                  // stray SOI / TEM: no length
        if (pos + 2 > size) { BKJLMessage(message, "The JPEG stream is cut short."); goto done; }
        uint32_t len = BKJLRead16(data + pos);
        if (len < 2 || pos + len > size) { BKJLMessage(message, "The JPEG stream is cut short."); goto done; }
        const uint8_t *seg = data + pos + 2;
        uint32_t segLen = len - 2;
        pos += len;
        if (m == 0xC3) {
            if (!BKJLReadFrameHeader(s, seg, segLen, message)) goto done;
            if (image) {
                image->width = s->width; image->height = s->height;
                image->components = s->componentCount; image->precision = s->precision;
            }
            if (headerOnly) { ok = 1; goto done; }
            if (out == NULL || outCount < (size_t)s->width * s->height * s->componentCount) { BKJLMessage(message, "The output buffer is too small."); goto done; }
            memset(out, 0, sizeof(uint16_t) * (size_t)s->width * s->height * s->componentCount);
        } else if (m == 0xC0 || m == 0xC1 || m == 0xC2) {
            BKJLMessage(message, "This is a lossy JPEG, not lossless JPEG."); goto done;
        } else if ((m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF) || m == 0xCC) {
            BKJLMessage(message, "Hierarchical or arithmetic-coded JPEG is not supported."); goto done;
        } else if (m == 0xC4) {
            if (!BKJLReadTables(s, seg, segLen, message)) goto done;
        } else if (m == 0xDD) {
            if (segLen < 2) { BKJLMessage(message, "Damaged JPEG restart interval."); goto done; }
            s->restartInterval = BKJLRead16(seg);
        } else if (m == 0xDA) {
            if (headerOnly) break;
            if (!BKJLDecodeScan(s, seg, segLen, data, size, &pos, out, message)) goto done;
            scans++;
        }
        // Everything else (APPn, COM, DQT, DNL after the frame) is skipped.
    }
    if (headerOnly) { BKJLMessage(message, "No lossless JPEG frame header found."); goto done; }
    if (!s->frameSeen) { BKJLMessage(message, "No lossless JPEG frame header found."); goto done; }
    if (scans == 0) { BKJLMessage(message, "The JPEG stream holds no image data."); goto done; }
    ok = 1;
done:
    free(s);
    return ok;
}

int BKJpegLosslessReadHeader(const uint8_t *data, size_t size, BKJpegLosslessImage *image, char *message)
{
    return BKJLRun(data, size, NULL, 0, image, message, 1);
}

int BKJpegLosslessDecode(const uint8_t *data, size_t size, uint16_t *out, size_t outCount,
                         BKJpegLosslessImage *image, char *message)
{
    return BKJLRun(data, size, out, outCount, image, message, 0);
}
