// Tests for BKContourCore (marching-squares outlines of a mask, joined into ordered lines).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// testMatchesRecordedVTK: the expected outline was RECORDED FROM THE CLASSIC ENGINE (2026-11-24, vtk-data): a
// scratch harness linked Boros' VTK 8.2 build, ran vtkMarchingSquares + vtkPolyDataConnectivityFilter (largest
// region) on this mask and listed the points in the order ITKSegmentation3D's old code read them (even point
// numbers forward, then odd numbers backward). On 400 generated masks (0/1 and 0/255 values, 1-3 blobs, largest
// region and all regions) the scratch harness found the same points in the same order. Numbers only - no VTK code
// is part of BorosKit.

#import <XCTest/XCTest.h>
#include "BKContourCore.h"

@interface BKContourCoreTests : XCTestCase
@end

// The recorder's 12 x 10 mask: a 7 x 6 block of 255 with its top-left pixel and one inner pixel cleared, plus one
// separate pixel.
static void BKTestMask(unsigned char img[120])
{
    memset(img, 0, 120);
    for (int y = 2; y < 8; y++) for (int x = 2; x < 9; x++) img[y * 12 + x] = 255;
    img[4 * 12 + 5] = 0; img[2 * 12 + 2] = 0; img[7 * 12 + 10] = 255;
}

@implementation BKContourCoreTests

- (void)testMatchesRecordedVTK
{
    unsigned char img[120];
    BKTestMask(img);
    BKContourLines L = { 0 };
    XCTAssertEqual(BKContourExtractU8(img, 12, 10, 12, 1, &L), 0);
    XCTAssertEqual(L.lineCount, 3);          // outer outline, the hole, the separate pixel
    int k = BKContourLargestLine(&L);
    XCTAssertEqual(k, 0);
    XCTAssertEqual(BKContourLineSegments(&L, 0), 26);
    XCTAssertEqual(BKContourLineSegments(&L, 1), 4);
    XCTAssertEqual(BKContourLineSegments(&L, 2), 4);
    const double e = 1.0 / 255.0;            // the level (1) sits 1/255 of the way from a 0 to a 255 pixel
    const double expect[26][2] = {
        { 2 + e, 2 }, { 2, 2 + e }, { 1 + e, 3 }, { 1 + e, 4 }, { 1 + e, 5 }, { 1 + e, 6 }, { 1 + e, 7 },
        { 2, 8 - e }, { 3, 8 - e }, { 4, 8 - e }, { 5, 8 - e }, { 6, 8 - e }, { 7, 8 - e }, { 8, 8 - e },
        { 9 - e, 7 }, { 9 - e, 6 }, { 9 - e, 5 }, { 9 - e, 4 }, { 9 - e, 3 }, { 9 - e, 2 },
        { 8, 1 + e }, { 7, 1 + e }, { 6, 1 + e }, { 5, 1 + e }, { 4, 1 + e }, { 3, 1 + e } };
    for (int i = 0; i < 26; i++)
    {
        XCTAssertEqualWithAccuracy(L.xy[2 * (L.lineStart[0] + i)], expect[i][0], 1e-6, @"x %d", i);
        XCTAssertEqualWithAccuracy(L.xy[2 * (L.lineStart[0] + i) + 1], expect[i][1], 1e-6, @"y %d", i);
    }
    XCTAssertTrue(L.lineClosed[0]);
    BKContourLinesFree(&L);
    XCTAssertEqual(L.lineCount, 0);
}

- (void)testMaskWithValueOneAndOpenLines
{
    // 0 / 1 mask with level 1: the outline runs through the centres of the border pixels (repeated points
    // dropped). A block touching the picture's right edge gives an open line.
    unsigned char img[6 * 5] = { 0 };
    for (int y = 1; y < 4; y++) for (int x = 1; x < 4; x++) img[y * 6 + x] = 1;   // 3 x 3 block
    BKContourLines L = { 0 };
    BKContourExtractU8(img, 6, 5, 6, 1, &L);
    XCTAssertEqual(L.lineCount, 1);
    XCTAssertTrue(L.lineClosed[0]);
    // The 8 border pixel centres of the block, each once.
    XCTAssertEqual(L.pointCount, 8);
    for (int i = 0; i < L.pointCount; i++)
    {
        double x = L.xy[2 * i], y = L.xy[2 * i + 1];
        XCTAssertTrue((x == 1 || x == 3 || y == 1 || y == 3) && x >= 1 && x <= 3 && y >= 1 && y <= 3, @"(%f,%f)", x, y);
    }
    BKContourLinesFree(&L);

    unsigned char edge[5 * 4] = { 0 };
    for (int y = 1; y < 3; y++) for (int x = 2; x < 5; x++) edge[y * 5 + x] = 200;
    BKContourExtractU8(edge, 5, 4, 5, 100, &L);
    XCTAssertEqual(L.lineCount, 1);
    XCTAssertFalse(L.lineClosed[0]);
    // Ends on the right border (x = 4), level halfway between 0 and 200.
    XCTAssertEqualWithAccuracy(L.xy[0], 4, 1e-12);
    XCTAssertEqualWithAccuracy(L.xy[2 * (L.pointCount - 1)], 4, 1e-12);
    BKContourLinesFree(&L);
}

- (void)testSaddleAndRowStride
{
    // Two diagonal pixels (a saddle in the middle square): average 127.5 >= 100 -> one joined outline;
    // level 200 -> average below -> two separate outlines. Rows padded to 8 bytes.
    unsigned char img[4 * 8];
    memset(img, 77, sizeof(img));            // padding bytes must be ignored
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) img[y * 8 + x] = 0;
    img[1 * 8 + 1] = 255; img[2 * 8 + 2] = 255;
    BKContourLines L = { 0 };
    BKContourExtractU8(img, 4, 4, 8, 100, &L);
    XCTAssertEqual(L.lineCount, 1);
    BKContourLinesFree(&L);
    BKContourExtractU8(img, 4, 4, 8, 200, &L);
    XCTAssertEqual(L.lineCount, 2);
    BKContourLinesFree(&L);
}

- (void)testEmptyAndBadInput
{
    unsigned char img[9] = { 0 };
    BKContourLines L = { 0 };
    XCTAssertEqual(BKContourExtractU8(img, 3, 3, 3, 1, &L), 0);
    XCTAssertEqual(L.lineCount, 0);
    XCTAssertEqual(BKContourLargestLine(&L), -1);
    BKContourLinesFree(&L);
    XCTAssertEqual(BKContourExtractU8(NULL, 3, 3, 3, 1, &L), -1);
    XCTAssertEqual(BKContourExtractU8(img, 3, 3, 2, 1, &L), -1);
    XCTAssertEqual(BKContourExtractU8(img, 1, 3, 1, 1, &L), 0);
}

@end
