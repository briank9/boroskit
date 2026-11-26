// BorosKit plain-C core tests: BKSegmentationCore (segmentations as label maps), 2026-11-26, agent "segmentation".
//
// Original BorosKit code written for this project; contains no third-party code.
//
// PORTING NOTES: plain C99, built by CMake on every platform (ctest core.seg_*). The same facts are checked on the
// Mac by Tests/BorosKitSegmentationTests (XCTest), which calls these very functions through bk_seg_run_all_c_tests.
//
// What is proven (known answers from phantoms, never from the code under test):
//   - the .boroseg file round-trips EXACTLY (grid bit for bit, every label, classes, information, unknown fields),
//     and saving twice gives identical bytes; damaged, cut-short or newer files are refused with the right status;
//   - voxel counts and volumes of box / ball phantoms (counted by hand here), also on a sheared grid (|det|);
//   - slice extraction == nearest plane sampling on the label grid; rotated and oblique planes hit the expected
//     voxels; planes outside the scan give background;
//   - overlay colours (class colour, opacity x overall opacity, hidden = transparent) and outline-only pixels;
//   - masks: padded box, and the CPU reference surface of a box mask is closed and lies exactly half a voxel outside
//     the box's voxel centres, in patient mm.

#include "BKCoreTest.h"
#include "BKSegmentationCore.h"
#include "BKSurfaceCore.h"
#include <stdlib.h>
#include <string.h>

#ifndef BK_TEST_OUTPUT_DIR
#define BK_TEST_OUTPUT_DIR "."
#endif

// A tilted, non-square grid used by several tests (axes are unit vectors; slice direction tilted by a gantry angle).
static BKLabelGrid SegTestGrid(uint32_t w, uint32_t h, uint32_t d)
{
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    g.dims[0] = w; g.dims[1] = h; g.dims[2] = d;
    g.spacing[0] = 0.3; g.spacing[1] = 0.35; g.spacing[2] = 0.5;
    g.origin[0] = -101.25; g.origin[1] = 12.5; g.origin[2] = -7.0 / 3.0;
    g.axes[0] = 1; g.axes[1] = 0; g.axes[2] = 0;
    g.axes[3] = 0; g.axes[4] = 1; g.axes[5] = 0;
    g.axes[6] = 0; g.axes[7] = 0.25881904510252074; g.axes[8] = 0.96592582628906831;   // 15 degrees tilt
    return g;
}

static BKLabelClass SegClass(uint16_t value, const char *name, const char *category, uint8_t r, uint8_t g, uint8_t b,
                             double opacity, int visible)
{
    BKLabelClass c;
    memset(&c, 0, sizeof c);
    c.value = value;
    strncpy(c.name, name, sizeof c.name - 1);
    strncpy(c.category, category, sizeof c.category - 1);
    c.rgb[0] = r; c.rgb[1] = g; c.rgb[2] = b;
    c.opacity = opacity;
    c.visible = visible;
    return c;
}

// Same grid, classes, information and labels.
static int SegSame(const BKLabelVolume *a, const BKLabelVolume *b, int compareVoxels)
{
    if (memcmp(BKLabelVolumeGetGrid(a), BKLabelVolumeGetGrid(b), sizeof(BKLabelGrid)) != 0) return 0;
    if (memcmp(BKLabelVolumeInfoConst(a), BKLabelVolumeInfoConst(b), sizeof(BKLabelInfo)) != 0) return 0;
    if (BKLabelVolumeClassCount(a) != BKLabelVolumeClassCount(b)) return 0;
    for (uint32_t i = 0; i < BKLabelVolumeClassCount(a); i++) {
        const BKLabelClass *x = BKLabelVolumeClassAtConst(a, i), *y = BKLabelVolumeClassAtConst(b, i);
        if (x->value != y->value || memcmp(x->rgb, y->rgb, 3) != 0 || x->visible != y->visible || x->opacity != y->opacity ||
            strcmp(x->name, y->name) != 0 || strcmp(x->category, y->category) != 0) return 0;
    }
    if (compareVoxels)
        return memcmp(BKLabelVolumeVoxelsConst(a), BKLabelVolumeVoxelsConst(b), (size_t)BKLabelVolumeVoxelCount(a) * 2) == 0;
    return 1;
}

static BKLabelVolume *SegTestVolume(void)
{
    BKLabelGrid g = SegTestGrid(13, 11, 7);
    BKLabelVolume *v = BKLabelVolumeCreate(&g);
    if (!v) return NULL;
    uint16_t *L = BKLabelVolumeVoxels(v);
    // A pattern with long runs, short runs, a high (16-bit) label and background.
    for (uint32_t k = 0; k < 7; k++)
        for (uint32_t j = 0; j < 11; j++)
            for (uint32_t i = 0; i < 13; i++) {
                uint16_t value = 0;
                if (i >= 2 && i < 9 && j >= 3 && j < 8) value = 1;
                if ((i + j + k) % 5 == 0) value = 7;
                if (k == 6 && j == 10) value = 60000;
                L[(k * 11 + j) * 13 + i] = value;
            }
    BKLabelClass c1 = SegClass(1, "Tooth 19 \"lower left first molar\"", "Lower teeth", 245, 238, 215, 1.0, 1);
    BKLabelClass c7 = SegClass(7, "Mandibular canal left\nline 2 \xC3\xBC", "Nerve canals", 216, 101, 79, 0.45, 0);
    BKLabelClass cH = SegClass(60000, "High value", "", 1, 2, 3, 0.1 + 0.2, 1);   // 0.30000000000000004
    BKLabelVolumeSetClass(v, &c1);
    BKLabelVolumeSetClass(v, &c7);
    BKLabelVolumeSetClass(v, &cH);
    BKLabelInfo *info = BKLabelVolumeInfo(v);
    strcpy(info->name, "AI dental (combined) 2026-11-25 18:45");
    strcpy(info->source, "BorosAI dental-combined");
    strcpy(info->created, "2026-11-25T18:45:03");
    strcpy(info->seriesInstanceUID, "1.2.826.0.1.3680043.8.498.12345678901234567890");
    return v;
}

void bk_test_seg_round_trip(void)
{
    BKLabelVolume *v = SegTestVolume();
    BK_CHECK(v != NULL);
    if (!v) return;
    uint8_t *bytes = NULL, *bytes2 = NULL;
    size_t size = 0, size2 = 0;
    BK_CHECK(BKLabelVolumeEncode(v, &bytes, &size) == BKSegStatusOK);
    BKLabelVolume *back = NULL;
    char msg[160] = "";
    BK_CHECK(BKLabelVolumeDecode(bytes, size, 0, &back, msg, sizeof msg) == BKSegStatusOK);
    BK_CHECK(back != NULL && SegSame(v, back, 1));
    // Deterministic: the decoded copy encodes to the very same bytes.
    BK_CHECK(back && BKLabelVolumeEncode(back, &bytes2, &size2) == BKSegStatusOK);
    BK_CHECK(size2 == size && bytes2 && memcmp(bytes, bytes2, size) == 0);
    // Header only: same grid, classes and information, no voxels.
    BKLabelVolume *head = NULL;
    BK_CHECK(BKLabelVolumeDecode(bytes, size, 1, &head, NULL, 0) == BKSegStatusOK);
    BK_CHECK(head && SegSame(v, head, 0) && BKLabelVolumeVoxelsConst(head) == NULL);
    // Files: save (via .tmp + rename), full load, header-only read.
    const char *path = BK_TEST_OUTPUT_DIR "/bk_seg_round_trip.boroseg";
    BK_CHECK(BKLabelVolumeSave(v, path) == BKSegStatusOK);
    BKLabelVolume *fromFile = NULL, *headFile = NULL;
    BK_CHECK(BKLabelVolumeLoad(path, &fromFile, msg, sizeof msg) == BKSegStatusOK);
    BK_CHECK(fromFile && SegSame(v, fromFile, 1));
    BK_CHECK(BKLabelVolumeReadHeader(path, &headFile, msg, sizeof msg) == BKSegStatusOK);
    BK_CHECK(headFile && SegSame(v, headFile, 0));
    // The awkward double (0.1 + 0.2) and the tilted axis survive bit for bit.
    BK_CHECK(fromFile && BKLabelVolumeFindClass(fromFile, 60000) && BKLabelVolumeFindClass(fromFile, 60000)->opacity == 0.1 + 0.2);
    remove(path);
    BKLabelVolumeFree(head); BKLabelVolumeFree(headFile); BKLabelVolumeFree(fromFile); BKLabelVolumeFree(back);
    BKSegFree(bytes); BKSegFree(bytes2);
    BKLabelVolumeFree(v);
}

// Replaces the header of an encoded file with `header` (a new length field), returns a new malloc'd file.
static uint8_t *SegWithHeader(const uint8_t *file, size_t size, const char *header, size_t *outSize)
{
    uint32_t oldH = (uint32_t)file[8] | ((uint32_t)file[9] << 8) | ((uint32_t)file[10] << 16) | ((uint32_t)file[11] << 24);
    size_t payload = size - 12 - oldH, newH = strlen(header);
    uint8_t *b = (uint8_t *)malloc(12 + newH + payload);
    memcpy(b, file, 8);
    b[8] = (uint8_t)newH; b[9] = (uint8_t)(newH >> 8); b[10] = (uint8_t)(newH >> 16); b[11] = (uint8_t)(newH >> 24);
    memcpy(b + 12, header, newH);
    memcpy(b + 12 + newH, file + 12 + oldH, payload);
    *outSize = 12 + newH + payload;
    return b;
}

void bk_test_seg_damaged_files(void)
{
    BKLabelVolume *v = SegTestVolume(), *out = NULL;
    uint8_t *bytes = NULL;
    size_t size = 0;
    BK_CHECK(v && BKLabelVolumeEncode(v, &bytes, &size) == BKSegStatusOK);
    if (!bytes) { BKLabelVolumeFree(v); return; }
    uint32_t H = (uint32_t)bytes[8] | ((uint32_t)bytes[9] << 8) | ((uint32_t)bytes[10] << 16) | ((uint32_t)bytes[11] << 24);
    char *header = (char *)malloc(H + 1);
    memcpy(header, bytes + 12, H);
    header[H] = 0;

    // One flipped bit in the label data -> checksum refuses it.
    uint8_t *copy = (uint8_t *)malloc(size);
    memcpy(copy, bytes, size);
    copy[size - 2] ^= 0x01;
    BK_CHECK(BKLabelVolumeDecode(copy, size, 0, &out, NULL, 0) == BKSegStatusChecksumMismatch && out == NULL);
    // Cut short -> wrong length.
    BK_CHECK(BKLabelVolumeDecode(bytes, size - 1, 0, &out, NULL, 0) == BKSegStatusBadFormat && out == NULL);
    // Not a segmentation file.
    memcpy(copy, bytes, size);
    copy[0] = 'X';
    BK_CHECK(BKLabelVolumeDecode(copy, size, 0, &out, NULL, 0) == BKSegStatusBadFormat);
    free(copy);

    // A newer version -> refused, never half-read.
    char *newer = (char *)malloc(H + 1);   // (no strdup: strict C99)
    memcpy(newer, header, H + 1);
    char *at = strstr(newer, "\"version\":1");
    BK_CHECK(at != NULL);
    if (at) at[10] = '2';
    size_t sizeNewer = 0;
    uint8_t *fileNewer = SegWithHeader(bytes, size, newer, &sizeNewer);
    BK_CHECK(BKLabelVolumeDecode(fileNewer, sizeNewer, 0, &out, NULL, 0) == BKSegStatusUnsupportedVersion);
    free(fileNewer); free(newer);

    // An unknown field (from a later Boros or BorosCMF) is kept through load + save.
    size_t hl = strlen(header);
    char *extended = (char *)malloc(hl + 64);
    memcpy(extended, header, hl);
    // header ends with "}\n": insert before the closing brace.
    size_t close = hl;
    while (close > 0 && extended[close - 1] != '}') close--;
    close--;
    strcpy(extended + close, ",\"futureField\":{\"a\":[1,2.5,\"x\"]}}\n");
    size_t sizeExt = 0;
    uint8_t *fileExt = SegWithHeader(bytes, size, extended, &sizeExt);
    BK_CHECK(BKLabelVolumeDecode(fileExt, sizeExt, 0, &out, NULL, 0) == BKSegStatusOK);
    uint8_t *again = NULL;
    size_t againSize = 0;
    BK_CHECK(out && BKLabelVolumeEncode(out, &again, &againSize) == BKSegStatusOK);
    if (again) {
        uint32_t H2 = (uint32_t)again[8] | ((uint32_t)again[9] << 8) | ((uint32_t)again[10] << 16) | ((uint32_t)again[11] << 24);
        char *h2 = (char *)malloc(H2 + 1);
        memcpy(h2, again + 12, H2);
        h2[H2] = 0;
        BK_CHECK(strstr(h2, "\"futureField\":{\"a\":[1,2.5,\"x\"]}") != NULL);
        free(h2);
    }
    BKSegFree(again);
    BKLabelVolumeFree(out);
    free(fileExt); free(extended); free(header);
    BKSegFree(bytes);
    BKLabelVolumeFree(v);
}

void bk_test_seg_counts_volumes(void)
{
    // Box phantom: 10 x 8 x 6 voxels of class 3 in a 32 x 30 x 20 grid; ball phantom: class 5.
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    g.dims[0] = 32; g.dims[1] = 30; g.dims[2] = 20;
    g.spacing[0] = 0.25; g.spacing[1] = 0.25; g.spacing[2] = 0.5;
    g.axes[0] = 1; g.axes[4] = 1; g.axes[8] = 1;
    BKLabelVolume *v = BKLabelVolumeCreate(&g);
    BK_CHECK(v != NULL);
    if (!v) return;
    uint16_t *L = BKLabelVolumeVoxels(v);
    uint64_t ball = 0;
    for (uint32_t k = 0; k < 20; k++)
        for (uint32_t j = 0; j < 30; j++)
            for (uint32_t i = 0; i < 32; i++) {
                uint16_t *p = &L[((uint64_t)k * 30 + j) * 32 + i];
                if (i >= 4 && i < 14 && j >= 5 && j < 13 && k >= 2 && k < 8) *p = 3;
                // ball: centre (24, 20, 14) voxels, radius 4 voxels in x/y, 2 in z (same 1 mm radius in mm)
                double dx = (i - 24.0) * 0.25, dy = (j - 20.0) * 0.25, dz = (k - 14.0) * 0.5;
                if (dx * dx + dy * dy + dz * dz <= 1.0) { *p = 5; ball++; }
            }
    uint64_t *counts = (uint64_t *)calloc(65536, sizeof(uint64_t));
    BK_CHECK(BKLabelVolumeCount(v, counts) == BKSegStatusOK);
    BK_CHECK(counts[3] == 480);
    BK_CHECK(counts[5] == ball && ball > 0);
    BK_CHECK(counts[0] == 32ull * 30 * 20 - 480 - ball);
    BK_CHECK_SAME(BKLabelGridVoxelVolume(&g), 0.03125);
    BK_CHECK_SAME(BKLabelGridVolumeOfCount(&g, counts[3]), 15.0);   // 480 x 0.03125 mm3, exact in binary
    uint32_t lo[3], hi[3];
    BK_CHECK(BKLabelVolumeClassBounds(v, 3, lo, hi) == 1);
    BK_CHECK(lo[0] == 4 && lo[1] == 5 && lo[2] == 2 && hi[0] == 13 && hi[1] == 12 && hi[2] == 7);
    BK_CHECK(BKLabelVolumeClassBounds(v, 9, lo, hi) == 0);
    // Removing a class clears its voxels.
    BKLabelClass c = SegClass(3, "Box", "", 1, 1, 1, 1, 1);
    BKLabelVolumeSetClass(v, &c);
    BK_CHECK(BKLabelVolumeRemoveClass(v, 3, 1) == 1 && BKLabelVolumeClassCount(v) == 0);
    BK_CHECK(BKLabelVolumeCount(v, counts) == BKSegStatusOK && counts[3] == 0);
    free(counts);
    BKLabelVolumeFree(v);

    // A sheared grid (columns 0.5 mm, rows 0.5 mm at 30 degrees to the columns, slices 2 mm): voxel volume =
    // 0.5 x 0.5 x sin(30) x 2 = 0.25 mm3.
    BKLabelGrid s;
    memset(&s, 0, sizeof s);
    s.dims[0] = s.dims[1] = s.dims[2] = 2;
    s.spacing[0] = 0.5; s.spacing[1] = 0.5; s.spacing[2] = 2;
    s.axes[0] = 1;
    s.axes[3] = 0.86602540378443865; s.axes[4] = 0.5;
    s.axes[8] = 1;
    BK_CHECK_NEAR(BKLabelGridVoxelVolume(&s), 0.25, 1e-15);
    // Voxel <-> patient round trip.
    double p[3], ijk[3];
    BKLabelGrid t = SegTestGrid(10, 10, 10);
    BKLabelGridVoxelToPatient(&t, 3, 4, 5, p);
    BK_CHECK(BKLabelGridPatientToVoxel(&t, p, ijk) == 1);
    BK_CHECK_NEAR(ijk[0], 3, 1e-12);
    BK_CHECK_NEAR(ijk[1], 4, 1e-12);
    BK_CHECK_NEAR(ijk[2], 5, 1e-12);
    // Hand-computed patient position of voxel (3, 4, 5) on the tilted grid.
    BK_CHECK_NEAR(p[0], -101.25 + 3 * 0.3, 1e-12);
    BK_CHECK_NEAR(p[1], 12.5 + 4 * 0.35 + 5 * 0.5 * 0.25881904510252074, 1e-12);
    BK_CHECK_NEAR(p[2], -7.0 / 3.0 + 5 * 0.5 * 0.96592582628906831, 1e-12);
}

void bk_test_seg_slices_planes(void)
{
    BKLabelVolume *v = SegTestVolume();
    BK_CHECK(v != NULL);
    if (!v) return;
    const BKLabelGrid *g = BKLabelVolumeGetGrid(v);
    const uint32_t w = g->dims[0], h = g->dims[1];
    uint16_t *slice = (uint16_t *)malloc(w * h * 2), *plane = (uint16_t *)malloc(w * h * 2);
    const uint16_t *L = BKLabelVolumeVoxelsConst(v);
    for (uint32_t k = 0; k < g->dims[2]; k++) {
        BK_CHECK(BKLabelVolumeExtractSlice(v, k, slice) == 1);
        BK_CHECK(memcmp(slice, L + (uint64_t)k * w * h, w * h * 2) == 0);
        // The same slice by plane sampling: origin = voxel (0, 0, k), steps = one column / one row.
        double o[3], u[3], vv[3];
        BKLabelGridVoxelToPatient(g, 0, 0, k, o);
        for (int a = 0; a < 3; a++) { u[a] = g->spacing[0] * g->axes[a]; vv[a] = g->spacing[1] * g->axes[3 + a]; }
        BK_CHECK(BKLabelVolumeSamplePlane(v, o, u, vv, w, h, plane) == 1);
        BK_CHECK(memcmp(plane, slice, w * h * 2) == 0);
        uint32_t kk = 99;
        int64_t i0 = 99, j0 = 99;
        BK_CHECK(BKLabelVolumePlaneIsGridSlice(v, o, u, vv, 0.01, &kk, &i0, &j0) == 1 && kk == k && i0 == 0 && j0 == 0);
    }
    // A plane between two slices (40 % of the way): nearest = the lower slice; 60 %: the upper one.
    double o[3], u[3], vv[3];
    for (int a = 0; a < 3; a++) { u[a] = g->spacing[0] * g->axes[a]; vv[a] = g->spacing[1] * g->axes[3 + a]; }
    BKLabelGridVoxelToPatient(g, 0, 0, 2.4, o);
    BKLabelVolumeSamplePlane(v, o, u, vv, w, h, plane);
    BK_CHECK(memcmp(plane, L + 2ull * w * h, w * h * 2) == 0);
    uint32_t kk;
    int64_t i0, j0;
    BK_CHECK(BKLabelVolumePlaneIsGridSlice(v, o, u, vv, 0.01, &kk, &i0, &j0) == 0);
    BKLabelGridVoxelToPatient(g, 0, 0, 2.6, o);
    BKLabelVolumeSamplePlane(v, o, u, vv, w, h, plane);
    BK_CHECK(memcmp(plane, L + 3ull * w * h, w * h * 2) == 0);
    // Swapped axes (u along rows, v along columns) on slice 4: the transposed slice.
    uint16_t *t = (uint16_t *)malloc(w * h * 2);
    BKLabelGridVoxelToPatient(g, 0, 0, 4, o);
    BKLabelVolumeSamplePlane(v, o, vv, u, h, w, t);
    int transposed = 1;
    for (uint32_t j = 0; j < h; j++)
        for (uint32_t i = 0; i < w; i++)
            if (t[i * h + j] != L[(4ull * h + j) * w + i]) transposed = 0;
    BK_CHECK(transposed);
    BK_CHECK(BKLabelVolumePlaneIsGridSlice(v, o, vv, u, 0.01, &kk, &i0, &j0) == 0);
    // An oblique plane: each sample checked against the hand rule floor(voxel coordinate + 0.5).
    // (Start chosen so no sample lands exactly half-way between two voxels: rounding a tie is a coin toss.)
    double ob[3] = { -100.013, 13.0071, -1.0029 }, ou[3] = { 0.21, 0.07, 0.03 }, ov[3] = { -0.05, 0.27, 0.11 };
    uint16_t obl[20 * 20];
    BK_CHECK(BKLabelVolumeSamplePlane(v, ob, ou, ov, 20, 20, obl) == 1);
    int obliqueOK = 1, inside = 0;
    for (int y = 0; y < 20; y++)
        for (int x = 0; x < 20; x++) {
            double p[3], ijk[3];
            for (int a = 0; a < 3; a++) p[a] = ob[a] + x * ou[a] + y * ov[a];
            BKLabelGridPatientToVoxel(g, p, ijk);
            long ix = (long)floor(ijk[0] + 0.5), iy = (long)floor(ijk[1] + 0.5), iz = (long)floor(ijk[2] + 0.5);
            uint16_t expect = 0;
            if (ix >= 0 && iy >= 0 && iz >= 0 && ix < (long)w && iy < (long)h && iz < (long)g->dims[2]) {
                expect = L[((uint64_t)iz * h + (uint64_t)iy) * w + (uint64_t)ix];
                inside++;
            }
            if (obl[y * 20 + x] != expect) {
                if (obliqueOK) printf("  oblique (%d,%d): got %u expected %u at voxel %.6f %.6f %.6f\n", x, y, obl[y * 20 + x], expect, ijk[0], ijk[1], ijk[2]);
                obliqueOK = 0;
            }
        }
    BK_CHECK(obliqueOK);
    BK_CHECK(inside > 50);
    if (inside <= 50) printf("  oblique samples inside the scan: %d\n", inside);
    // Far outside the scan: all background.
    double far[3] = { 500, 500, 500 };
    BKLabelVolumeSamplePlane(v, far, u, vv, w, h, plane);
    int empty = 1;
    for (uint32_t n = 0; n < w * h; n++) if (plane[n]) empty = 0;
    BK_CHECK(empty);
    free(t); free(slice); free(plane);
    BKLabelVolumeFree(v);
}

void bk_test_seg_overlay_picture(void)
{
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    g.dims[0] = 9; g.dims[1] = 7; g.dims[2] = 1;
    g.spacing[0] = g.spacing[1] = g.spacing[2] = 1;
    g.axes[0] = 1; g.axes[4] = 1; g.axes[8] = 1;
    BKLabelVolume *v = BKLabelVolumeCreate(&g);
    BK_CHECK(v != NULL);
    if (!v) return;
    uint16_t *L = BKLabelVolumeVoxels(v);
    for (uint32_t j = 1; j < 6; j++) for (uint32_t i = 2; i < 7; i++) L[j * 9 + i] = 2;   // 5 x 5 square
    L[0] = 4;                                                                             // hidden class pixel
    BKLabelClass c2 = SegClass(2, "Square", "", 200, 100, 50, 0.5, 1), c4 = SegClass(4, "Hidden", "", 9, 9, 9, 1, 0);
    BKLabelVolumeSetClass(v, &c2);
    BKLabelVolumeSetClass(v, &c4);
    uint8_t *table = (uint8_t *)malloc(BKLabelColourTableBytes);
    BKLabelColourTableBuild(v, 0.4, table);
    BK_CHECK(table[8] == 200 && table[9] == 100 && table[10] == 50 && table[11] == 51);   // round(0.5 x 0.4 x 255) = 51
    BK_CHECK(table[16 + 3] == 0 && table[3] == 0 && table[4 * 3 + 3] == 0);              // hidden, background, unknown
    uint8_t rgba[9 * 7 * 4];
    uint32_t box[4];
    BK_CHECK(BKLabelSliceToRGBA(L, 9, 7, table, 0, rgba, box) == 25);
    BK_CHECK(box[0] == 2 && box[1] == 1 && box[2] == 5 && box[3] == 5);
    BK_CHECK(rgba[(3 * 9 + 4) * 4 + 3] == 51 && rgba[3] == 0);
    // Outline: the 16 border pixels of the 5 x 5 square; the 3 x 3 inside is transparent.
    BK_CHECK(BKLabelSliceToRGBA(L, 9, 7, table, 1, rgba, box) == 16);
    BK_CHECK(rgba[(3 * 9 + 4) * 4 + 3] == 0 && rgba[(1 * 9 + 2) * 4 + 3] == 51);
    // Overall opacity 0: nothing.
    BKLabelColourTableBuild(v, 0, table);
    BK_CHECK(BKLabelSliceToRGBA(L, 9, 7, table, 0, rgba, box) == 0 && box[2] == 0);
    free(table);
    BKLabelVolumeFree(v);
}

// Every edge of a closed (watertight) indexed mesh belongs to exactly two triangles, once in each direction.
static int SegMeshClosed(const BKSurfaceMeshData *m)
{
    uint64_t E = m->triangleCount * 3;
    uint64_t *keys = (uint64_t *)malloc(E * sizeof(uint64_t));
    if (!keys) return 0;
    for (uint64_t t = 0; t < m->triangleCount; t++)
        for (int e = 0; e < 3; e++) {
            uint64_t a = m->indices[3 * t + e], b = m->indices[3 * t + (e + 1) % 3];
            keys[3 * t + e] = (a << 32) | b;
        }
    // Each directed edge (a, b) must appear once and its reverse (b, a) once: check by brute force (small mesh).
    int ok = 1;
    for (uint64_t x = 0; x < E && ok; x++) {
        uint64_t rev = (keys[x] << 32) | (keys[x] >> 32);
        int same = 0, back = 0;
        for (uint64_t y = 0; y < E; y++) { if (keys[y] == keys[x]) same++; if (keys[y] == rev) back++; }
        if (same != 1 || back != 1) ok = 0;
    }
    free(keys);
    return ok;
}

void bk_test_seg_mask_surface(void)
{
    // A 3 x 4 x 2 voxel box (class 6) touching the scan's edge at i = 0 (the padding outside the scan closes it).
    BKLabelGrid g;
    memset(&g, 0, sizeof g);
    g.dims[0] = 8; g.dims[1] = 9; g.dims[2] = 6;
    g.spacing[0] = 0.5; g.spacing[1] = 0.25; g.spacing[2] = 1.0;
    g.origin[0] = 10; g.origin[1] = -20; g.origin[2] = 30;
    g.axes[0] = 1; g.axes[4] = 1; g.axes[8] = 1;
    BKLabelVolume *v = BKLabelVolumeCreate(&g);
    BK_CHECK(v != NULL);
    if (!v) return;
    uint16_t *L = BKLabelVolumeVoxels(v);
    for (uint32_t k = 2; k < 4; k++) for (uint32_t j = 3; j < 7; j++) for (uint32_t i = 0; i < 3; i++) L[(k * 9 + j) * 8 + i] = 6;
    int64_t bmin[3];
    uint32_t bdim[3];
    BK_CHECK(BKLabelMaskBox(v, 6, 2, bmin, bdim) == 1);
    BK_CHECK(bmin[0] == -2 && bmin[1] == 1 && bmin[2] == 0 && bdim[0] == 7 && bdim[1] == 8 && bdim[2] == 6);
    float *mask = (float *)malloc(sizeof(float) * bdim[0] * bdim[1] * bdim[2]);
    BKLabelMaskFillFloat(v, 6, bmin, bdim, mask);
    double inside = 0;
    for (uint32_t n = 0; n < bdim[0] * bdim[1] * bdim[2]; n++) inside += mask[n];
    BK_CHECK_SAME(inside, 24);
    // 16-bit fill of slices 2..3 only gives the same voxels.
    uint16_t *m16 = (uint16_t *)malloc(2 * bdim[0] * bdim[1] * 2);
    BKLabelMaskFill16(v, 6, bmin, bdim, 2, 2, 65535, m16);
    int same16 = 1;
    for (uint32_t n = 0; n < bdim[0] * bdim[1] * 2; n++)
        if ((m16[n] == 65535) != (mask[2 * bdim[0] * bdim[1] + n] == 1.0f)) same16 = 0;
    BK_CHECK(same16);
    // CPU reference surface at 0.5 in patient mm.
    double toPatient[16];
    BKLabelMaskBoxToPatient(&g, bmin, toPatient);
    BKSurfaceMeshData mesh;
    memset(&mesh, 0, sizeof mesh);
    BK_CHECK(BKSurfaceReferenceExtract(mask, bdim[0], bdim[1], bdim[2], 0.5f, toPatient, &mesh) == BKSurfaceStatusOK);
    BK_CHECK(mesh.triangleCount > 0 && SegMeshClosed(&mesh));
    double lo[3] = { 1e9, 1e9, 1e9 }, hi[3] = { -1e9, -1e9, -1e9 };
    for (uint64_t n = 0; n < mesh.vertexCount; n++)
        for (int a = 0; a < 3; a++) {
            double c = mesh.positions[4 * n + a];
            if (c < lo[a]) lo[a] = c;
            if (c > hi[a]) hi[a] = c;
        }
    // Voxel centres i 0..2, j 3..6, k 2..3; the 0.5 level lies half a voxel outside them.
    BK_CHECK_NEAR(lo[0], 10 + (-0.5) * 0.5, 1e-5);
    BK_CHECK_NEAR(hi[0], 10 + 2.5 * 0.5, 1e-5);
    BK_CHECK_NEAR(lo[1], -20 + 2.5 * 0.25, 1e-5);
    BK_CHECK_NEAR(hi[1], -20 + 6.5 * 0.25, 1e-5);
    BK_CHECK_NEAR(lo[2], 30 + 1.5, 1e-5);
    BK_CHECK_NEAR(hi[2], 30 + 3.5, 1e-5);
    BKSurfaceMeshDataFree(&mesh);
    free(m16); free(mask);
    BKLabelVolumeFree(v);
}
