// BorosKit Vulkan tests: BKPNGWrite - see BKPNGWrite.h.
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-26 by agent "vulkan-engine" (step M10).

#include "BKPNGWrite.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// CRC-32 (polynomial 0xEDB88320, reflected), table built on first use.
static uint32_t bk_png_crc(const uint8_t *data, size_t n, uint32_t crc)
{
    static uint32_t table[256];
    static int ready = 0;
    if (!ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = 1;
    }
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

static void bk_png_be32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }

// One chunk: length, type, data, CRC over type + data.
static int bk_png_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t n)
{
    uint8_t head[8];
    bk_png_be32(head, n);
    memcpy(head + 4, type, 4);
    uint32_t crc = bk_png_crc(head + 4, 4, 0xFFFFFFFFu);
    if (n) crc = bk_png_crc(data, n, crc);
    crc ^= 0xFFFFFFFFu;
    uint8_t tail[4];
    bk_png_be32(tail, crc);
    return fwrite(head, 1, 8, f) == 8 && (n == 0 || fwrite(data, 1, n, f) == n) && fwrite(tail, 1, 4, f) == 4 ? 0 : -1;
}

int bk_png_write_rgba8(const char *path, const uint8_t *rgba, uint32_t width, uint32_t height)
{
    if (!path || !rgba || width == 0 || height == 0) return -1;
    // Raw scanlines: filter byte 0 + the row.
    size_t row = (size_t)width * 4 + 1, raw = row * height;
    uint8_t *lines = (uint8_t *)malloc(raw);
    if (!lines) return -1;
    for (uint32_t y = 0; y < height; y++) {
        lines[y * row] = 0;
        memcpy(lines + y * row + 1, rgba + (size_t)y * width * 4, (size_t)width * 4);
    }
    // zlib stream: header (deflate, 32 KB window, no dictionary, check bits), stored blocks, Adler-32.
    size_t blocks = (raw + 65534) / 65535;
    size_t zsize = 2 + raw + blocks * 5 + 4;
    uint8_t *z = (uint8_t *)malloc(zsize);
    if (!z) { free(lines); return -1; }
    size_t o = 0;
    z[o++] = 0x78; z[o++] = 0x01;
    uint32_t a = 1, b = 0;
    for (size_t done = 0; done < raw;) {
        size_t n = raw - done > 65535 ? 65535 : raw - done;
        z[o++] = (uint8_t)(done + n == raw ? 1 : 0);     // BFINAL, BTYPE = 00 (stored)
        z[o++] = (uint8_t)n; z[o++] = (uint8_t)(n >> 8);
        z[o++] = (uint8_t)~n; z[o++] = (uint8_t)(~n >> 8);
        memcpy(z + o, lines + done, n);
        for (size_t i = 0; i < n; i++) { a = (a + lines[done + i]) % 65521u; b = (b + a) % 65521u; }
        o += n;
        done += n;
    }
    bk_png_be32(z + o, (b << 16) | a);
    o += 4;
    uint8_t ihdr[13];
    bk_png_be32(ihdr, width);
    bk_png_be32(ihdr + 4, height);
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;   // 8-bit RGBA, no interlace
    FILE *f = fopen(path, "wb");
    int ok = -1;
    if (f) {
        static const uint8_t signature[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
        ok = fwrite(signature, 1, 8, f) == 8 && bk_png_chunk(f, "IHDR", ihdr, 13) == 0 &&
             bk_png_chunk(f, "IDAT", z, (uint32_t)o) == 0 && bk_png_chunk(f, "IEND", NULL, 0) == 0 ? 0 : -1;
        if (fclose(f) != 0) ok = -1;
    }
    free(z);
    free(lines);
    return ok;
}
