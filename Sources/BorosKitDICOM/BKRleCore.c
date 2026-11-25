// BorosKitDICOM: BKRleCore - see BKRleCore.h.
//
// Original BorosKit code written for this project; contains no third-party code (DICOM PS3.5 Annex G).

#include "BKRleCore.h"

#include <string.h>
#include <stdio.h>

static uint32_t BKRleRead32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

int BKRleDecodeFrame(const uint8_t *data, size_t size, size_t pixels, uint32_t samples, uint32_t bytesPerSample,
                     uint8_t *out, char *message)
{
    if (data == NULL || out == NULL || size < 64 || samples == 0 || bytesPerSample == 0 || bytesPerSample > 4) {
        if (message) snprintf(message, 256, "Damaged RLE image (no header).");
        return 0;
    }
    uint32_t segments = BKRleRead32(data);
    uint32_t expected = samples * bytesPerSample;
    if (segments != expected || segments > 15) {
        if (message) snprintf(message, 256, "The RLE image has %u byte planes, %u expected.", segments, expected);
        return 0;
    }
    const size_t stride = (size_t)samples * bytesPerSample;
    for (uint32_t seg = 0; seg < segments; seg++) {
        uint32_t start = BKRleRead32(data + 4 + 4 * seg);
        uint32_t stop = (seg + 1 < segments) ? BKRleRead32(data + 8 + 4 * seg) : (uint32_t)size;
        if (start < 64 || start > size || stop > size || stop < start) {
            if (message) snprintf(message, 256, "Damaged RLE image (bad segment offsets).");
            return 0;
        }
        // Segment order: sample 0 most significant byte ... least, then sample 1, ...
        uint32_t sample = seg / bytesPerSample;
        uint32_t byteFromTop = seg % bytesPerSample;
        size_t outByte = (size_t)sample * bytesPerSample + (bytesPerSample - 1 - byteFromTop);   // little endian
        size_t produced = 0, p = start;
        while (produced < pixels && p < stop) {
            int8_t n = (int8_t)data[p++];
            if (n >= 0) {                      // copy the next n + 1 bytes
                size_t count = (size_t)n + 1;
                if (p + count > stop) count = stop - p;
                for (size_t i = 0; i < count && produced < pixels; i++) out[produced++ * stride + outByte] = data[p + i];
                p += (size_t)n + 1;
            } else if (n != -128) {            // repeat the next byte 1 - n times
                if (p >= stop) break;
                size_t count = (size_t)(1 - n);
                uint8_t v = data[p++];
                for (size_t i = 0; i < count && produced < pixels; i++) out[produced++ * stride + outByte] = v;
            }                                  // -128: no operation
        }
        if (produced < pixels) {
            if (message) snprintf(message, 256, "The RLE image is cut short.");
            return 0;
        }
    }
    return 1;
}
