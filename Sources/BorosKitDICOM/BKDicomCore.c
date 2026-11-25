// BorosKitDICOM: BKDicomCore - see BKDicomCore.h.
//
// Original BorosKit code written for this project; contains no third-party code.
// Written from the DICOM standard's description of the encoding (PS3.5 sections 7 and A.4, PS3.10).

#include "BKDicomCore.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

#define BK_UNDEFINED_LENGTH 0xFFFFFFFFu
#define BK_MAX_DEPTH 12

// ---- Little helpers -----------------------------------------------------------------------------

static void BKSetMessage(char *message, const char *text)
{
    if (message == NULL) return;
    snprintf(message, BK_DICOM_MESSAGE, "%s", text);
}

static uint16_t BKRead16(const uint8_t *p, int bigEndian)
{
    return bigEndian ? (uint16_t)((p[0] << 8) | p[1]) : (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t BKRead32(const uint8_t *p, int bigEndian)
{
    return bigEndian ? ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]
                     : (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// What: copies a string value into a fixed buffer, trimming spaces / NULs at both ends (DICOM pads values to
// an even length with a space or NUL). Never overflows: long values are cut.
static void BKCopyString(char *dst, size_t dstSize, const uint8_t *value, size_t length)
{
    while (length > 0 && (value[0] == ' ' || value[0] == 0)) { value++; length--; }
    while (length > 0 && (value[length - 1] == ' ' || value[length - 1] == 0)) length--;
    if (length >= dstSize) length = dstSize - 1;
    memcpy(dst, value, length);
    dst[length] = 0;
}

int BKDicomParseNumber(const char *value, size_t length, int index, double *out)
{
    // Find the index-th backslash-separated part.
    size_t start = 0;
    for (int part = 0; part < index; part++) {
        while (start < length && value[start] != '\\') start++;
        if (start >= length) return 0;
        start++;
    }
    size_t end = start;
    while (end < length && value[end] != '\\') end++;
    char buffer[64];
    size_t n = end - start;
    if (n == 0 || n >= sizeof(buffer)) return 0;
    memcpy(buffer, value + start, n);
    buffer[n] = 0;
    char *endPtr = NULL;
    double v = strtod(buffer, &endPtr);
    // Only spaces may follow the number.
    if (endPtr == buffer) return 0;
    while (*endPtr == ' ' || *endPtr == 0) { if (*endPtr == 0) break; endPtr++; }
    if (*endPtr != 0 || !isfinite(v)) return 0;
    *out = v;
    return 1;
}

// ---- Transfer syntaxes --------------------------------------------------------------------------

BKDicomSyntax BKDicomSyntaxFromUID(const char *uid)
{
    BKDicomSyntax s;
    memset(&s, 0, sizeof(s));
    s.explicitVR = 1;
    if (uid == NULL || uid[0] == 0 || strcmp(uid, "1.2.840.10008.1.2") == 0) {
        s.explicitVR = 0;
        snprintf(s.name, sizeof(s.name), "Implicit VR Little Endian");
    } else if (strcmp(uid, "1.2.840.10008.1.2.1") == 0) {
        snprintf(s.name, sizeof(s.name), "Explicit VR Little Endian");
    } else if (strcmp(uid, "1.2.840.10008.1.2.2") == 0) {
        s.bigEndian = 1;
        snprintf(s.name, sizeof(s.name), "Explicit VR Big Endian");
    } else if (strcmp(uid, "1.2.840.10008.1.2.1.99") == 0) {
        s.compression = BKDicomCompressionDeflate;
        snprintf(s.name, sizeof(s.name), "Deflated Explicit VR Little Endian");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.50") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEGBaseline;
        snprintf(s.name, sizeof(s.name), "JPEG Baseline (8-bit)");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.51") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEGExtended;
        snprintf(s.name, sizeof(s.name), "JPEG Extended (12-bit)");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.57") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEGLossless;
        snprintf(s.name, sizeof(s.name), "JPEG Lossless (process 14)");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.70") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEGLossless;
        snprintf(s.name, sizeof(s.name), "JPEG Lossless (SV1)");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.90") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEG2000;
        snprintf(s.name, sizeof(s.name), "JPEG 2000 (lossless)");
    } else if (strcmp(uid, "1.2.840.10008.1.2.4.91") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionJPEG2000;
        snprintf(s.name, sizeof(s.name), "JPEG 2000");
    } else if (strcmp(uid, "1.2.840.10008.1.2.5") == 0) {
        s.encapsulated = 1; s.compression = BKDicomCompressionRLE;
        snprintf(s.name, sizeof(s.name), "RLE Lossless");
    } else {
        // Every other image syntax (JPEG-LS .4.80/.81, HTJ2K .4.201-203, MPEG / H.264 / HEVC video, private
        // ones) is encapsulated with explicit VR little endian, so the file can still be listed.
        s.encapsulated = 1;
        s.compression = BKDicomCompressionUnsupported;
        if (strncmp(uid, "1.2.840.10008.1.2.4.8", 21) == 0) snprintf(s.name, sizeof(s.name), "JPEG-LS");
        else if (strncmp(uid, "1.2.840.10008.1.2.4.20", 22) == 0) snprintf(s.name, sizeof(s.name), "High-Throughput JPEG 2000");
        else if (strncmp(uid, "1.2.840.10008.1.2.4.10", 22) == 0) snprintf(s.name, sizeof(s.name), "Video (MPEG / H.264 / HEVC)");
        else snprintf(s.name, sizeof(s.name), "Unknown (%.40s)", uid);
    }
    return s;
}

// ---- The walker ---------------------------------------------------------------------------------

typedef struct {
    const uint8_t *data;
    size_t size;
    int bigEndian;
    BKDicomInfo *info;
    char *message;
    int stopAtPixelData;
    int finished;              // pixel data reached (top level): stop walking
    int depth;
    uint32_t pathTag[BK_MAX_DEPTH];
    int32_t pathItem[BK_MAX_DEPTH];
} BKWalker;

#define BK_TAG(g, e) (((uint32_t)(g) << 16) | (uint32_t)(e))

// VRs whose length field is 32 bits (after two reserved bytes) in explicit VR.
static int BKIsLongVR(const char vr[2])
{
    static const char *const longVRs[] = { "OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV" };
    for (size_t i = 0; i < sizeof(longVRs) / sizeof(longVRs[0]); i++)
        if (vr[0] == longVRs[i][0] && vr[1] == longVRs[i][1]) return 1;
    return 0;
}

// Sequences whose contents matter (enhanced multi-frame geometry), so they are entered even with a defined
// length; all other defined-length sequences are skipped as one block.
static int BKIsGeometrySequence(uint32_t tag)
{
    switch (tag) {
        case BK_TAG(0x5200, 0x9229):   // Shared Functional Groups Sequence
        case BK_TAG(0x5200, 0x9230):   // Per-frame Functional Groups Sequence
        case BK_TAG(0x0020, 0x9113):   // Plane Position Sequence
        case BK_TAG(0x0020, 0x9116):   // Plane Orientation Sequence
        case BK_TAG(0x0028, 0x9110):   // Pixel Measures Sequence
        case BK_TAG(0x0028, 0x9145):   // Pixel Value Transformation Sequence
        case BK_TAG(0x0028, 0x9132):   // Frame VOI LUT Sequence
            return 1;
        default:
            return 0;
    }
}

// Binary unsigned-short attributes read by tag (implicit VR has no VR to tell us).
static int BKIsUSTag(uint32_t tag)
{
    switch (tag) {
        case BK_TAG(0x0028, 0x0002): case BK_TAG(0x0028, 0x0006): case BK_TAG(0x0028, 0x0010):
        case BK_TAG(0x0028, 0x0011): case BK_TAG(0x0028, 0x0100): case BK_TAG(0x0028, 0x0101):
        case BK_TAG(0x0028, 0x0102): case BK_TAG(0x0028, 0x0103):
            return 1;
        default:
            return 0;
    }
}

static int BKInPath(const BKWalker *w, uint32_t tag, int32_t *item)
{
    for (int i = 0; i < w->depth; i++)
        if (w->pathTag[i] == tag) { if (item) *item = w->pathItem[i]; return 1; }
    return 0;
}

static int BKEnsurePerFrame(BKDicomInfo *info, uint32_t index)
{
    if (index < info->perFrameCount) return 1;
    if (index > 1000000) return 0;
    uint32_t n = index + 1;
    double *p = (double *)realloc(info->framePositions, sizeof(double) * 3 * n);
    if (!p) return 0;
    info->framePositions = p;
    double *o = (double *)realloc(info->frameOrientations, sizeof(double) * 6 * n);
    if (!o) return 0;
    info->frameOrientations = o;
    double *r = (double *)realloc(info->frameRescale, sizeof(double) * 2 * n);
    if (!r) return 0;
    info->frameRescale = r;
    for (uint32_t i = info->perFrameCount; i < n; i++) {
        for (int k = 0; k < 3; k++) info->framePositions[i * 3 + k] = NAN;
        for (int k = 0; k < 6; k++) info->frameOrientations[i * 6 + k] = NAN;
        for (int k = 0; k < 2; k++) info->frameRescale[i * 2 + k] = NAN;
    }
    info->perFrameCount = n;
    return 1;
}

// What: reads n numbers of a DS value into out; returns how many were read.
static int BKReadNumbers(const uint8_t *value, uint32_t length, double *out, int n)
{
    int got = 0;
    for (int i = 0; i < n; i++) {
        if (!BKDicomParseNumber((const char *)value, length, i, &out[i])) break;
        got++;
    }
    return got;
}

// What: an unsigned integer attribute, binary (US / UL / SS) or text (IS / DS), by its VR.
static int BKReadUnsigned(const BKWalker *w, const char vr[2], int explicitVR, uint32_t tag, const uint8_t *value,
                          uint32_t length, uint32_t *out)
{
    int binary = explicitVR ? (vr[0] == 'U' && (vr[1] == 'S' || vr[1] == 'L')) || (vr[0] == 'S' && vr[1] == 'S')
                            : BKIsUSTag(tag);
    if (binary) {
        if ((vr[1] == 'L') && explicitVR && length >= 4) { *out = BKRead32(value, w->bigEndian); return 1; }
        if (length >= 2) { *out = BKRead16(value, w->bigEndian); return 1; }
        return 0;
    }
    double d;
    if (!BKDicomParseNumber((const char *)value, length, 0, &d) || d < 0 || d > 4294967295.0) return 0;
    *out = (uint32_t)d;
    return 1;
}

// What: keeps one element's value if the viewer needs it. Top-level elements fill the main fields; inside
// the functional group sequences only geometry / rescale / window elements are used (shared = main fields,
// per-frame = the per-frame arrays).
static void BKVisit(BKWalker *w, uint32_t tag, const char vr[2], int explicitVR, const uint8_t *value, uint32_t length)
{
    BKDicomInfo *info = w->info;
    int32_t frame = -1;
    int perFrame = w->depth > 0 && BKInPath(w, BK_TAG(0x5200, 0x9230), &frame);
    int shared = w->depth > 0 && !perFrame && BKInPath(w, BK_TAG(0x5200, 0x9229), NULL);
    if (w->depth > 0 && !perFrame && !shared) return;   // other nested sequences: not needed
    if (perFrame && (frame < 0 || !BKEnsurePerFrame(info, (uint32_t)frame))) return;
    double numbers[6];
    uint32_t u;
    switch (tag) {
        case BK_TAG(0x0020, 0x0032):   // Image Position (Patient)
            if (BKReadNumbers(value, length, numbers, 3) == 3) {
                if (perFrame) memcpy(&info->framePositions[frame * 3], numbers, sizeof(double) * 3);
                else { memcpy(info->imagePosition, numbers, sizeof(double) * 3); info->hasPosition = 1; }
            }
            return;
        case BK_TAG(0x0020, 0x0037):   // Image Orientation (Patient)
            if (BKReadNumbers(value, length, numbers, 6) == 6) {
                if (perFrame) memcpy(&info->frameOrientations[frame * 6], numbers, sizeof(double) * 6);
                else { memcpy(info->imageOrientation, numbers, sizeof(double) * 6); info->hasOrientation = 1; }
            }
            return;
        case BK_TAG(0x0028, 0x1052):   // Rescale Intercept
            if (BKReadNumbers(value, length, numbers, 1) == 1) {
                if (perFrame) info->frameRescale[frame * 2 + 1] = numbers[0]; else info->rescaleIntercept = numbers[0];
            }
            return;
        case BK_TAG(0x0028, 0x1053):   // Rescale Slope
            if (BKReadNumbers(value, length, numbers, 1) == 1 && numbers[0] != 0) {
                if (perFrame) info->frameRescale[frame * 2] = numbers[0]; else info->rescaleSlope = numbers[0];
            }
            return;
        default:
            break;
    }
    if (perFrame) return;   // per frame: only the values above vary per frame here
    switch (tag) {
        case BK_TAG(0x0028, 0x0030):   // Pixel Spacing
            if (BKReadNumbers(value, length, numbers, 2) == 2 && numbers[0] > 0 && numbers[1] > 0) {
                info->pixelSpacing[0] = numbers[0]; info->pixelSpacing[1] = numbers[1]; info->hasPixelSpacing = 1;
            }
            return;
        case BK_TAG(0x0018, 0x1164):   // Imager Pixel Spacing (used only when Pixel Spacing is missing)
            if (!info->hasPixelSpacing && BKReadNumbers(value, length, numbers, 2) == 2 && numbers[0] > 0 && numbers[1] > 0) {
                info->pixelSpacing[0] = numbers[0]; info->pixelSpacing[1] = numbers[1];
            }
            return;
        case BK_TAG(0x0018, 0x0050):   // Slice Thickness
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->sliceThickness = fabs(numbers[0]);
            return;
        case BK_TAG(0x0018, 0x0088):   // Spacing Between Slices
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->spacingBetweenSlices = fabs(numbers[0]);
            return;
        case BK_TAG(0x0028, 0x1050):   // Window Center
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->windowCenter = numbers[0];
            return;
        case BK_TAG(0x0028, 0x1051):   // Window Width
            if (BKReadNumbers(value, length, numbers, 1) == 1 && numbers[0] > 0) info->windowWidth = numbers[0];
            return;
        default:
            break;
    }
    if (shared) return;   // the rest is top level only
    switch (tag) {
        case BK_TAG(0x0008, 0x0005): BKCopyString(info->characterSet, sizeof(info->characterSet), value, length); return;
        case BK_TAG(0x0008, 0x0016): BKCopyString(info->sopClassUID, sizeof(info->sopClassUID), value, length); return;
        case BK_TAG(0x0008, 0x0018): BKCopyString(info->sopInstanceUID, sizeof(info->sopInstanceUID), value, length); return;
        case BK_TAG(0x0008, 0x0020): BKCopyString(info->studyDate, sizeof(info->studyDate), value, length); return;
        case BK_TAG(0x0008, 0x0021): BKCopyString(info->seriesDate, sizeof(info->seriesDate), value, length); return;
        case BK_TAG(0x0008, 0x0030): BKCopyString(info->studyTime, sizeof(info->studyTime), value, length); return;
        case BK_TAG(0x0008, 0x0031): BKCopyString(info->seriesTime, sizeof(info->seriesTime), value, length); return;
        case BK_TAG(0x0008, 0x0060): BKCopyString(info->modality, sizeof(info->modality), value, length); return;
        case BK_TAG(0x0008, 0x0070): BKCopyString(info->manufacturer, sizeof(info->manufacturer), value, length); return;
        case BK_TAG(0x0008, 0x1030): BKCopyString(info->studyDescription, sizeof(info->studyDescription), value, length); return;
        case BK_TAG(0x0008, 0x103E): BKCopyString(info->seriesDescription, sizeof(info->seriesDescription), value, length); return;
        case BK_TAG(0x0008, 0x1090): BKCopyString(info->modelName, sizeof(info->modelName), value, length); return;
        case BK_TAG(0x0010, 0x0010): BKCopyString(info->patientName, sizeof(info->patientName), value, length); return;
        case BK_TAG(0x0010, 0x0020): BKCopyString(info->patientID, sizeof(info->patientID), value, length); return;
        case BK_TAG(0x0010, 0x0030): BKCopyString(info->patientBirthDate, sizeof(info->patientBirthDate), value, length); return;
        case BK_TAG(0x0010, 0x0040): BKCopyString(info->patientSex, sizeof(info->patientSex), value, length); return;
        case BK_TAG(0x0018, 0x0015): BKCopyString(info->bodyPart, sizeof(info->bodyPart), value, length); return;
        case BK_TAG(0x0020, 0x000D): BKCopyString(info->studyInstanceUID, sizeof(info->studyInstanceUID), value, length); return;
        case BK_TAG(0x0020, 0x000E): BKCopyString(info->seriesInstanceUID, sizeof(info->seriesInstanceUID), value, length); return;
        case BK_TAG(0x0020, 0x0052): BKCopyString(info->frameOfReferenceUID, sizeof(info->frameOfReferenceUID), value, length); return;
        case BK_TAG(0x0020, 0x0011):
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->seriesNumber = (int32_t)numbers[0];
            return;
        case BK_TAG(0x0020, 0x0013):
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->instanceNumber = (int32_t)numbers[0];
            return;
        case BK_TAG(0x0020, 0x1041):
            if (BKReadNumbers(value, length, numbers, 1) == 1) info->sliceLocation = numbers[0];
            return;
        case BK_TAG(0x0028, 0x0004): BKCopyString(info->photometric, sizeof(info->photometric), value, length); return;
        case BK_TAG(0x0028, 0x0002): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->samplesPerPixel = u; return;
        case BK_TAG(0x0028, 0x0006): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->planarConfiguration = u; return;
        case BK_TAG(0x0028, 0x0008): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u) && u > 0) info->numberOfFrames = u; return;
        case BK_TAG(0x0028, 0x0010): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->rows = u; return;
        case BK_TAG(0x0028, 0x0011): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->columns = u; return;
        case BK_TAG(0x0028, 0x0100): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->bitsAllocated = u; return;
        case BK_TAG(0x0028, 0x0101): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->bitsStored = u; return;
        case BK_TAG(0x0028, 0x0102): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->highBit = u; return;
        case BK_TAG(0x0028, 0x0103): if (BKReadUnsigned(w, vr, explicitVR, tag, value, length, &u)) info->pixelRepresentation = u; return;
        default:
            return;
    }
}

static BKDicomStatus BKFail(BKWalker *w, BKDicomStatus status, const char *text)
{
    BKSetMessage(w->message, text);
    return status;
}

static int BKAddFragment(BKDicomInfo *info, size_t offset, size_t length)
{
    if ((info->fragmentCount & 63) == 0) {
        size_t n = (size_t)info->fragmentCount + 64;
        size_t *o = (size_t *)realloc(info->fragmentOffsets, sizeof(size_t) * n);
        if (!o) return 0;
        info->fragmentOffsets = o;
        size_t *l = (size_t *)realloc(info->fragmentLengths, sizeof(size_t) * n);
        if (!l) return 0;
        info->fragmentLengths = l;
    }
    info->fragmentOffsets[info->fragmentCount] = offset;
    info->fragmentLengths[info->fragmentCount] = length;
    info->fragmentCount++;
    return 1;
}

// What: the items of encapsulated pixel data: first the basic offset table, then the fragments, up to the
// sequence delimiter. Item headers in encapsulated data are always little endian.
static BKDicomStatus BKReadEncapsulated(BKWalker *w, size_t pos)
{
    BKDicomInfo *info = w->info;
    int first = 1;
    while (1) {
        if (pos + 8 > w->size) return BKFail(w, BKDicomErrorTruncated, "The compressed pixel data is cut short (file incomplete).");
        uint16_t g = BKRead16(w->data + pos, 0), e = BKRead16(w->data + pos + 2, 0);
        uint32_t len = BKRead32(w->data + pos + 4, 0);
        pos += 8;
        if (g == 0xFFFE && e == 0xE0DD) break;
        if (g != 0xFFFE || e != 0xE000 || len == BK_UNDEFINED_LENGTH)
            return BKFail(w, BKDicomErrorMalformed, "The compressed pixel data is not laid out as DICOM fragments.");
        if (len > w->size - pos) return BKFail(w, BKDicomErrorTruncated, "A compressed image fragment is cut short (file incomplete).");
        if (first) {
            first = 0;
            uint32_t n = len / 4;
            if (n > 0) {
                info->offsetTable = (uint32_t *)malloc(sizeof(uint32_t) * n);
                if (!info->offsetTable) return BKFail(w, BKDicomErrorNoMemory, "Out of memory.");
                for (uint32_t i = 0; i < n; i++) info->offsetTable[i] = BKRead32(w->data + pos + 4 * i, 0);
                info->offsetTableCount = n;
            }
        } else if (!BKAddFragment(info, pos, len)) {
            return BKFail(w, BKDicomErrorNoMemory, "Out of memory.");
        }
        pos += len;
    }
    return BKDicomOK;
}

static BKDicomStatus BKWalkDataset(BKWalker *w, size_t pos, size_t end, int explicitVR, int untilItemEnd, size_t *next);

// What: the items of one sequence starting at `pos` (length `length`, maybe undefined). Each item's
// contents are walked as a dataset with the sequence's encoding.
static BKDicomStatus BKWalkSequence(BKWalker *w, uint32_t tag, size_t pos, uint32_t length, int explicitVR, size_t *next)
{
    size_t end = (length == BK_UNDEFINED_LENGTH) ? w->size : pos + length;
    if (w->depth >= BK_MAX_DEPTH) return BKFail(w, BKDicomErrorMalformed, "Sequences are nested too deeply.");
    int32_t item = 0;
    w->pathTag[w->depth] = tag;
    w->depth++;
    BKDicomStatus status = BKDicomOK;
    while (pos + 8 <= end) {
        uint16_t g = BKRead16(w->data + pos, w->bigEndian), e = BKRead16(w->data + pos + 2, w->bigEndian);
        uint32_t len = BKRead32(w->data + pos + 4, w->bigEndian);
        if (g == 0xFFFE && e == 0xE0DD) { pos += 8; end = pos; break; }   // sequence delimiter
        if (g != 0xFFFE || e != 0xE000) { status = BKFail(w, BKDicomErrorMalformed, "A sequence holds something that is not an item."); break; }
        pos += 8;
        w->pathItem[w->depth - 1] = item;
        size_t after = pos;
        if (len == BK_UNDEFINED_LENGTH) {
            status = BKWalkDataset(w, pos, w->size, explicitVR, 1, &after);
        } else {
            if (len > end - pos) { status = BKFail(w, BKDicomErrorTruncated, "A sequence item is cut short (file incomplete)."); break; }
            status = BKWalkDataset(w, pos, pos + len, explicitVR, 0, &after);
            after = pos + len;
        }
        if (status != BKDicomOK) break;
        pos = after;
        item++;
    }
    w->depth--;
    if (status != BKDicomOK) return status;
    if (length == BK_UNDEFINED_LENGTH && end == w->size && pos + 8 > w->size)
        return BKFail(w, BKDicomErrorTruncated, "A sequence has no end marker (file incomplete).");
    *next = (length == BK_UNDEFINED_LENGTH) ? pos : end;
    return BKDicomOK;
}

// What: walks the elements from `pos` to `end` (or to the item delimiter when untilItemEnd).
static BKDicomStatus BKWalkDataset(BKWalker *w, size_t pos, size_t end, int explicitVR, int untilItemEnd, size_t *next)
{
    while (pos < end && !w->finished) {
        if (end - pos < 8) {
            if (untilItemEnd) return BKFail(w, BKDicomErrorTruncated, "The file ends inside a sequence item.");
            break;   // a few stray padding bytes at the very end of a file: ignore
        }
        const uint8_t *p = w->data + pos;
        uint16_t g = BKRead16(p, w->bigEndian), e = BKRead16(p + 2, w->bigEndian);
        uint32_t tag = BK_TAG(g, e);
        if (g == 0xFFFE) {
            if (e == 0xE00D && untilItemEnd) { *next = pos + 8; return BKDicomOK; }
            return BKFail(w, BKDicomErrorMalformed, "An item marker appears outside a sequence.");
        }
        char vr[3] = { 'U', 'N', 0 };
        uint32_t len;
        size_t header;
        int elementExplicit = explicitVR;
        // Some writers mix encodings; an "explicit" element whose VR bytes are not letters is read as implicit.
        if (elementExplicit && !(p[4] >= 'A' && p[4] <= 'Z' && p[5] >= 'A' && p[5] <= 'Z')) elementExplicit = 0;
        if (elementExplicit) {
            vr[0] = (char)p[4]; vr[1] = (char)p[5];
            if (BKIsLongVR(vr)) {
                if (end - pos < 12) return BKFail(w, BKDicomErrorTruncated, "The file ends inside an element header.");
                len = BKRead32(p + 8, w->bigEndian);
                header = 12;
            } else {
                len = BKRead16(p + 6, w->bigEndian);
                header = 8;
            }
        } else {
            len = BKRead32(p + 4, w->bigEndian);
            header = 8;
            if (tag == BK_TAG(0x7FE0, 0x0010)) { vr[0] = 'O'; vr[1] = 'W'; }
        }
        size_t valuePos = pos + header;
        if (tag == BK_TAG(0x7FE0, 0x0010) && w->depth == 0) {
            // Pixel Data: native (defined length) or encapsulated (undefined length).
            BKDicomInfo *info = w->info;
            info->hasPixelData = 1;
            memcpy(info->pixelDataVR, vr, 3);
            if (len == BK_UNDEFINED_LENGTH) {
                info->syntax.encapsulated = 1;
                BKDicomStatus s = BKReadEncapsulated(w, valuePos);
                if (s != BKDicomOK) return s;
            } else {
                if (len > w->size - valuePos) {
                    // Keep what is there; BKDicomCanDecode reports the shortfall in plain words.
                    len = (uint32_t)(w->size - valuePos);
                }
                info->pixelDataOffset = valuePos;
                info->pixelDataLength = len;
            }
            w->finished = 1;   // nothing after the pixel data matters to a viewer
            break;
        }
        if (len == BK_UNDEFINED_LENGTH) {
            // A sequence (SQ, or UN / implicit of undefined length, which per the standard holds an
            // implicit VR little endian sequence when the VR is UN).
            int innerExplicit = (elementExplicit && vr[0] == 'U' && vr[1] == 'N') ? 0 : explicitVR;
            size_t after = valuePos;
            BKDicomStatus s = BKWalkSequence(w, tag, valuePos, len, innerExplicit, &after);
            if (s != BKDicomOK) return s;
            pos = after;
            continue;
        }
        if (len > end - valuePos || valuePos > end) {
            if (untilItemEnd || w->depth > 0) return BKFail(w, BKDicomErrorTruncated, "An element inside a sequence is cut short (file incomplete).");
            return BKFail(w, BKDicomErrorTruncated, "The file is cut short (an element runs past the end).");
        }
        int isSequence = elementExplicit ? (vr[0] == 'S' && vr[1] == 'Q') : 0;
        if (BKIsGeometrySequence(tag) && (isSequence || !elementExplicit)) {
            size_t after = valuePos;
            BKDicomStatus s = BKWalkSequence(w, tag, valuePos, len, explicitVR, &after);
            if (s != BKDicomOK) return s;
        } else if (!isSequence) {
            BKVisit(w, tag, vr, elementExplicit, w->data + valuePos, len);
        }
        pos = valuePos + len;
    }
    *next = pos;
    return BKDicomOK;
}

static void BKInfoDefaults(BKDicomInfo *info)
{
    memset(info, 0, sizeof(*info));
    info->seriesNumber = INT32_MIN;
    info->instanceNumber = INT32_MIN;
    info->numberOfFrames = 1;
    info->samplesPerPixel = 1;
    info->rescaleSlope = 1.0;
    info->rescaleIntercept = 0.0;
    info->sliceLocation = NAN;
    info->pixelSpacing[0] = info->pixelSpacing[1] = 1.0;
}

static BKDicomStatus BKFinishInfo(BKWalker *w, BKDicomStatus status)
{
    BKDicomInfo *info = w->info;
    if (status != BKDicomOK) return status;
    if (info->bitsStored == 0) info->bitsStored = info->bitsAllocated;
    if (info->highBit == 0 || info->highBit + 1 < info->bitsStored) info->highBit = info->bitsStored ? info->bitsStored - 1 : 0;
    if (info->photometric[0] == 0) snprintf(info->photometric, sizeof(info->photometric), "%s",
                                            info->samplesPerPixel == 3 ? "RGB" : "MONOCHROME2");
    return BKDicomOK;
}

BKDicomStatus BKDicomParseDataset(const uint8_t *data, size_t size, BKDicomSyntax syntax, BKDicomInfo *info, char *message)
{
    BKWalker w;
    memset(&w, 0, sizeof(w));
    w.data = data; w.size = size; w.bigEndian = syntax.bigEndian; w.info = info; w.message = message;
    info->syntax = syntax;
    size_t next = 0;
    BKDicomStatus s = BKWalkDataset(&w, 0, size, syntax.explicitVR, 0, &next);
    return BKFinishInfo(&w, s);
}

BKDicomStatus BKDicomParseFile(const uint8_t *data, size_t size, BKDicomInfo *info, char *message)
{
    BKInfoDefaults(info);
    if (message) message[0] = 0;
    if (data == NULL || size < 8) { BKSetMessage(message, "The file is too small to be DICOM."); return BKDicomErrorNotDicom; }
    BKWalker w;
    memset(&w, 0, sizeof(w));
    w.data = data; w.size = size; w.info = info; w.message = message;

    size_t pos = 0;
    int part10 = size >= 132 && memcmp(data + 128, "DICM", 4) == 0;
    if (part10) pos = 132;

    // File meta information (group 0002): always explicit VR little endian.
    int sawMeta = 0;
    while (pos + 8 <= size) {
        uint16_t g = BKRead16(data + pos, 0);
        if (g != 0x0002) break;
        uint16_t e = BKRead16(data + pos + 2, 0);
        char vr[3] = { (char)data[pos + 4], (char)data[pos + 5], 0 };
        uint32_t len;
        size_t header;
        if (!(vr[0] >= 'A' && vr[0] <= 'Z' && vr[1] >= 'A' && vr[1] <= 'Z')) {   // implicit meta (very old writers)
            len = BKRead32(data + pos + 4, 0); header = 8;
        } else if (BKIsLongVR(vr)) {
            if (pos + 12 > size) break;
            len = BKRead32(data + pos + 8, 0); header = 12;
        } else {
            len = BKRead16(data + pos + 6, 0); header = 8;
        }
        if (len == BK_UNDEFINED_LENGTH || len > size - pos - header) {
            BKSetMessage(message, "The DICOM file header is damaged.");
            return BKDicomErrorMalformed;
        }
        if (e == 0x0010) BKCopyString(info->transferSyntaxUID, sizeof(info->transferSyntaxUID), data + pos + header, len);
        if (e == 0x0002 && info->sopClassUID[0] == 0) BKCopyString(info->sopClassUID, sizeof(info->sopClassUID), data + pos + header, len);
        pos += header + len;
        sawMeta = 1;
    }

    if (!part10 && !sawMeta) {
        // No preamble and no file meta: a bare dataset (old ACR-NEMA style or raw network dumps). Accept it only
        // when it starts like one - a low group number with a plausible header - and guess explicit vs implicit.
        uint16_t g = BKRead16(data, 0);
        if (g == 0 || g > 0x0040 || (g & 1)) { BKSetMessage(message, "Not a DICOM file."); return BKDicomErrorNotDicom; }
        int looksExplicit = data[4] >= 'A' && data[4] <= 'Z' && data[5] >= 'A' && data[5] <= 'Z';
        info->syntax = BKDicomSyntaxFromUID(looksExplicit ? "1.2.840.10008.1.2.1" : "1.2.840.10008.1.2");
    } else {
        info->syntax = BKDicomSyntaxFromUID(info->transferSyntaxUID);
    }
    if (part10 && !sawMeta) {
        // "DICM" but no group 2: some writers skip the meta; guess the encoding from the first element.
        int looksExplicit = pos + 6 <= size && data[pos + 4] >= 'A' && data[pos + 4] <= 'Z' && data[pos + 5] >= 'A' && data[pos + 5] <= 'Z';
        info->syntax = BKDicomSyntaxFromUID(looksExplicit ? "1.2.840.10008.1.2.1" : "1.2.840.10008.1.2");
    }

    info->datasetOffset = pos;
    if (info->syntax.compression == BKDicomCompressionDeflate) {
        BKSetMessage(message, "The dataset is deflated; inflate it first.");
        return BKDicomErrorNeedsInflate;
    }
    w.bigEndian = info->syntax.bigEndian;
    size_t next = pos;
    BKDicomStatus s = BKWalkDataset(&w, pos, size, info->syntax.explicitVR, 0, &next);
    return BKFinishInfo(&w, s);
}

void BKDicomInfoFree(BKDicomInfo *info)
{
    if (info == NULL) return;
    free(info->framePositions); info->framePositions = NULL;
    free(info->frameOrientations); info->frameOrientations = NULL;
    free(info->frameRescale); info->frameRescale = NULL;
    info->perFrameCount = 0;
    free(info->fragmentOffsets); info->fragmentOffsets = NULL;
    free(info->fragmentLengths); info->fragmentLengths = NULL;
    info->fragmentCount = 0;
    free(info->offsetTable); info->offsetTable = NULL;
    info->offsetTableCount = 0;
}

// ---- Can it be shown? -----------------------------------------------------------------------------

size_t BKDicomNativeFrameBytes(const BKDicomInfo *info)
{
    return (size_t)info->rows * info->columns * info->samplesPerPixel * (info->bitsAllocated / 8);
}

int BKDicomCanDecode(const BKDicomInfo *info, char *message)
{
    char text[BK_DICOM_MESSAGE];
    if (!info->hasPixelData) { BKSetMessage(message, "This file holds no image (no pixel data), e.g. a report or structured data."); return 0; }
    if (info->rows == 0 || info->columns == 0) { BKSetMessage(message, "The image size (rows / columns) is missing."); return 0; }
    if (info->syntax.compression == BKDicomCompressionUnsupported) {
        snprintf(text, sizeof(text), "Images compressed as %s cannot be opened yet.", info->syntax.name);
        BKSetMessage(message, text);
        return 0;
    }
    if (info->samplesPerPixel != 1 && info->samplesPerPixel != 3) {
        snprintf(text, sizeof(text), "%u samples per pixel are not supported.", info->samplesPerPixel);
        BKSetMessage(message, text);
        return 0;
    }
    const char *pi = info->photometric;
    int mono = strcmp(pi, "MONOCHROME1") == 0 || strcmp(pi, "MONOCHROME2") == 0;
    int colour = strcmp(pi, "RGB") == 0 || strcmp(pi, "YBR_FULL") == 0 ||
                 ((strcmp(pi, "YBR_FULL_422") == 0 || strcmp(pi, "YBR_ICT") == 0 || strcmp(pi, "YBR_RCT") == 0) && info->syntax.encapsulated);
    if (!(mono && info->samplesPerPixel == 1) && !(colour && info->samplesPerPixel == 3)) {
        snprintf(text, sizeof(text), "The colour format \"%s\" with %u sample(s) per pixel is not supported.", pi, info->samplesPerPixel);
        BKSetMessage(message, text);
        return 0;
    }
    if (info->bitsAllocated != 8 && info->bitsAllocated != 16 && info->bitsAllocated != 32) {
        snprintf(text, sizeof(text), "%u bits per pixel are not supported.", info->bitsAllocated);
        BKSetMessage(message, text);
        return 0;
    }
    if (info->bitsStored == 0 || info->bitsStored > info->bitsAllocated) { BKSetMessage(message, "The bits-stored value is invalid."); return 0; }
    if (!info->syntax.encapsulated) {
        size_t frame = BKDicomNativeFrameBytes(info);
        if (frame == 0 || info->pixelDataLength / frame < info->numberOfFrames) {
            BKSetMessage(message, "The pixel data is shorter than the image size says (file incomplete or damaged).");
            return 0;
        }
    } else if (info->fragmentCount == 0) {
        BKSetMessage(message, "The compressed pixel data holds no image fragments.");
        return 0;
    }
    return 1;
}

// ---- Pixel values -----------------------------------------------------------------------------------

void BKDicomFrameRescale(const BKDicomInfo *info, uint32_t frame, double *slope, double *intercept)
{
    *slope = info->rescaleSlope;
    *intercept = info->rescaleIntercept;
    if (frame < info->perFrameCount && info->frameRescale) {
        if (!isnan(info->frameRescale[frame * 2])) *slope = info->frameRescale[frame * 2];
        if (!isnan(info->frameRescale[frame * 2 + 1])) *intercept = info->frameRescale[frame * 2 + 1];
    }
}

int BKDicomFrameOrientation(const BKDicomInfo *info, uint32_t frame, double orientation[6])
{
    if (frame < info->perFrameCount && info->frameOrientations && !isnan(info->frameOrientations[frame * 6])) {
        memcpy(orientation, &info->frameOrientations[frame * 6], sizeof(double) * 6);
        return 1;
    }
    if (!info->hasOrientation) return 0;
    memcpy(orientation, info->imageOrientation, sizeof(double) * 6);
    return 1;
}

int BKDicomFramePosition(const BKDicomInfo *info, uint32_t frame, double position[3])
{
    if (frame < info->perFrameCount && info->framePositions && !isnan(info->framePositions[frame * 3])) {
        memcpy(position, &info->framePositions[frame * 3], sizeof(double) * 3);
        return 1;
    }
    if (!info->hasPosition) return 0;
    memcpy(position, info->imagePosition, sizeof(double) * 3);
    if (frame > 0) {
        // Classic multi-frame without per-frame positions: frames stacked along the slice normal.
        double o[6];
        if (!BKDicomFrameOrientation(info, frame, o)) return 0;
        double n[3] = { o[1] * o[5] - o[2] * o[4], o[2] * o[3] - o[0] * o[5], o[0] * o[4] - o[1] * o[3] };
        double step = info->spacingBetweenSlices > 0 ? info->spacingBetweenSlices : info->sliceThickness;
        if (!(step > 0)) return 0;
        for (int k = 0; k < 3; k++) position[k] += n[k] * step * frame;
    }
    return 1;
}

int BKDicomStoredToValues(const BKDicomInfo *info, uint32_t frame, const uint8_t *stored, size_t storedBytes,
                          int bigEndian, int swapOW8, float *out)
{
    const uint32_t ba = info->bitsAllocated, bs = info->bitsStored, spp = info->samplesPerPixel;
    if ((ba != 8 && ba != 16 && ba != 32) || bs == 0 || bs > ba || (spp != 1 && spp != 3) || stored == NULL || out == NULL) return 0;
    const size_t n = (size_t)info->rows * info->columns;
    const size_t bytesPerSample = ba / 8;
    if (storedBytes < n * spp * bytesPerSample) return 0;
    double slope, intercept;
    BKDicomFrameRescale(info, frame, &slope, &intercept);
    const uint32_t shift = (info->highBit + 1 >= bs) ? info->highBit + 1 - bs : 0;
    const uint64_t mask = (bs >= 32) ? 0xFFFFFFFFull : ((1ull << bs) - 1);
    const int isSigned = info->pixelRepresentation == 1;
    const int planar = spp == 3 && info->planarConfiguration == 1;
    const int ybr = spp == 3 && strncmp(info->photometric, "YBR", 3) == 0;

    for (size_t p = 0; p < n; p++) {
        double samples[3] = { 0, 0, 0 };
        for (uint32_t s = 0; s < spp; s++) {
            size_t index = planar ? (size_t)s * n + p : p * spp + s;
            uint64_t raw;
            if (ba == 8) raw = stored[swapOW8 ? (index ^ 1) : index];
            else if (ba == 16) raw = BKRead16(stored + index * 2, bigEndian);
            else raw = BKRead32(stored + index * 4, bigEndian);
            raw = (raw >> shift) & mask;
            int64_t v = (int64_t)raw;
            if (isSigned && bs < 64 && (raw & (1ull << (bs - 1)))) v = (int64_t)raw - (int64_t)(1ull << bs);
            samples[s] = (double)v;
        }
        double value;
        if (spp == 1) value = samples[0];
        else if (ybr) value = samples[0];
        else value = 0.299 * samples[0] + 0.587 * samples[1] + 0.114 * samples[2];
        out[p] = (float)(value * slope + intercept);
    }
    return 1;
}

int BKDicomDecodeNativeFrame(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame,
                             float *out, char *message)
{
    if (info->syntax.encapsulated) { BKSetMessage(message, "The pixel data is compressed."); return 0; }
    if (!BKDicomCanDecode(info, message)) return 0;
    if (frame >= info->numberOfFrames) { BKSetMessage(message, "No such frame."); return 0; }
    size_t frameBytes = BKDicomNativeFrameBytes(info);
    size_t start = info->pixelDataOffset + frameBytes * frame;
    if (start + frameBytes > size) { BKSetMessage(message, "The pixel data is cut short."); return 0; }
    int swapOW8 = info->syntax.bigEndian && info->bitsAllocated == 8 && info->pixelDataVR[0] == 'O' && info->pixelDataVR[1] == 'W';
    if (!BKDicomStoredToValues(info, frame, data + start, frameBytes, info->syntax.bigEndian, swapOW8, out)) {
        BKSetMessage(message, "The pixel layout is not supported.");
        return 0;
    }
    return 1;
}

// ---- Fragments of encapsulated frames -----------------------------------------------------------------

static int BKFragmentStartsFrame(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t k)
{
    size_t o = info->fragmentOffsets[k];
    if (info->fragmentLengths[k] < 2 || o + 2 > size) return 0;
    const uint8_t *p = data + o;
    switch (info->syntax.compression) {
        case BKDicomCompressionJPEGBaseline:
        case BKDicomCompressionJPEGExtended:
        case BKDicomCompressionJPEGLossless:
            return p[0] == 0xFF && p[1] == 0xD8;
        case BKDicomCompressionJPEG2000:
            // A raw codestream starts with SOC (FF4F); a JP2 file with its signature box (00 00 00 0C 6A 50).
            return (p[0] == 0xFF && p[1] == 0x4F) ||
                   (info->fragmentLengths[k] >= 6 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 0x0C && p[4] == 0x6A && p[5] == 0x50);
        default:
            return 1;   // RLE: one fragment per frame
    }
}

int BKDicomFrameFragments(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame,
                          uint32_t *first, uint32_t *count)
{
    uint32_t F = info->numberOfFrames, n = info->fragmentCount;
    if (n == 0 || frame >= F) return 0;
    if (F == 1) { *first = 0; *count = n; return 1; }
    if (info->offsetTableCount == F && info->offsetTable) {
        // Frame starts given as offsets from the first fragment's item header (8 bytes before its data).
        size_t base = info->fragmentOffsets[0] - 8;
        uint32_t start = UINT32_MAX, stop = n;
        for (uint32_t k = 0; k < n; k++) {
            size_t rel = info->fragmentOffsets[k] - 8 - base;
            if (rel == info->offsetTable[frame]) start = k;
            if (frame + 1 < F && rel == info->offsetTable[frame + 1]) { stop = k; break; }
        }
        if (start != UINT32_MAX && stop > start) { *first = start; *count = stop - start; return 1; }
        // Inconsistent table: fall through to the other rules.
    }
    if (n == F) { *first = frame; *count = 1; return 1; }
    // Several fragments per frame without a usable table: find the frame starts by their markers.
    uint32_t seen = 0, start = UINT32_MAX;
    for (uint32_t k = 0; k < n; k++) {
        if (BKFragmentStartsFrame(info, data, size, k)) {
            if (seen == frame) start = k;
            else if (seen == frame + 1) { *first = start; *count = k - start; return 1; }
            seen++;
        }
    }
    if (start != UINT32_MAX && seen == frame + 1) { *first = start; *count = n - start; return 1; }
    return 0;
}

uint8_t *BKDicomCopyFrameBytes(const BKDicomInfo *info, const uint8_t *data, size_t size, uint32_t frame, size_t *length)
{
    uint32_t first, count;
    if (!BKDicomFrameFragments(info, data, size, frame, &first, &count)) return NULL;
    size_t total = 0;
    for (uint32_t k = first; k < first + count; k++) {
        if (info->fragmentOffsets[k] + info->fragmentLengths[k] > size) return NULL;
        total += info->fragmentLengths[k];
    }
    uint8_t *bytes = (uint8_t *)malloc(total ? total : 1);
    if (!bytes) return NULL;
    size_t at = 0;
    for (uint32_t k = first; k < first + count; k++) {
        memcpy(bytes + at, data + info->fragmentOffsets[k], info->fragmentLengths[k]);
        at += info->fragmentLengths[k];
    }
    *length = total;
    return bytes;
}
