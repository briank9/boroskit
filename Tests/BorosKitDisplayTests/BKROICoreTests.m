// Tests for BKROICore against the values RECORDED from the old Horos ROI code
// (References/roi-reference-2026-11-16.json: 18 ROIs of every kind on a synthetic 64 x 48 image).
//
// Original BorosKit code written for this project; contains no third-party code.

#import <XCTest/XCTest.h>
#include "BKROICore.h"
#include <math.h>
#include <float.h>

@interface BKROICoreTests : XCTestCase
@end

// The recorded image: same formula and float steps as the recorder (README in References).
static float RecValue(long x, long y)
{
    return 7.25f * (float)x + 1.5f * (float)y + 100.0f * sinf(0.37f * (float)x) * cosf(0.21f * (float)y) - 300.0f;
}

// A recorded number ("nan" / "inf" written as text).
static double Num(id v)
{
    if ([v isKindOfClass:[NSString class]]) {
        if ([v isEqual:@"nan"]) return NAN;
        return [v hasPrefix:@"-"] ? -INFINITY : INFINITY;
    }
    return [v doubleValue];
}

// Same float value (NaN equal to NaN).
static BOOL SameFloat(float a, double recorded)
{
    float r = (float)recorded;
    return (isnan(a) && isnan(r)) || a == r;
}

// Within 4 float steps (units in the last place). Used ONLY for the values whose last binary digits the
// old build's "fast maths" setting (GCC_FAST_MATH, Release) changed by letting the compiler reorder sums
// and turn divisions into multiplications: centroid shares, SD. Far below anything displayed.
static BOOL NearFloat(double a, double recorded)
{
    if (isnan(a) || isnan(recorded)) return isnan(a) && isnan(recorded);
    return fabs(a - recorded) <= 4.0 * (double)FLT_EPSILON * fmax(fabs(recorded), 1e-30);
}

@implementation BKROICoreTests

- (NSDictionary *)reference
{
    NSString *dir = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"References/roi-reference-2026-11-16.json"]];
    XCTAssertNotNil(data, @"reference file missing");
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

- (void)testAgainstRecordedOldValues
{
    NSDictionary *ref = [self reference];
    const int32_t W = [ref[@"image"][@"width"] intValue], H = [ref[@"image"][@"height"] intValue];
    // The recorder's image was made with float pixel sizes 0.5f / 0.7f (held as double by the ROIs).
    const double sx = (double)0.5f, sy = (double)0.7f;
    float *image = malloc(sizeof(float) * W * H);
    for (long y = 0; y < H; y++) for (long x = 0; x < W; x++) image[y * W + x] = RecValue(x, y);
    // The recorded pixel values are the authority (the recorder's build fused some multiply-adds, so the
    // formula can differ in the last digit): every recorded inside pixel overrides the formula.
    for (NSDictionary *r in ref[@"rois"]) {
        NSArray *locs = r[@"inside"][@"locations"], *vals = r[@"inside"][@"values"];
        for (NSUInteger i = 0; i < locs.count; i++) {
            long x = [locs[i][0] longValue], y = [locs[i][1] longValue];
            if (x >= 0 && x < W && y >= 0 && y < H) image[y * W + x] = (float)Num(vals[i]);
        }
    }

    for (NSDictionary *r in ref[@"rois"]) {
        NSString *name = r[@"name"];
        NSArray *rp = r[@"points"], *rect = r[@"rect"];
        int32_t kind = [r[@"type"] intValue];
        // Input points: the user's points (recorded as the ROI's points for the point-list kinds).
        BKROIPoint pts[16];
        uint32_t n = 0;
        BOOL rectKind = (kind == BKROIKindRect || kind == BKROIKindOval || kind == BKROIKindPoint);
        if (!rectKind) for (NSArray *p in rp) { pts[n].x = [p[0] doubleValue]; pts[n].y = [p[1] doubleValue]; n++; }
        BKROIShape s = { kind, pts, n, [rect[0] doubleValue], [rect[1] doubleValue], [rect[2] doubleValue],
                         [rect[3] doubleValue], sx, sy, 1, 0 };

        // Outline = the recorded points.
        BKROIPointList outline = BKROIOutline(&s);
        XCTAssertEqual(outline.count, (uint32_t)rp.count, @"%@ outline count", name);
        for (uint32_t i = 0; i < outline.count && i < rp.count; i++) {
            XCTAssertEqual(outline.points[i].x, [rp[i][0] doubleValue], @"%@ outline %u x", name, i);
            XCTAssertEqual(outline.points[i].y, [rp[i][1] doubleValue], @"%@ outline %u y", name, i);
        }

        // Curve.
        BKROIPointList curve = BKROICurve(&s, 5.0);
        NSArray *rs = r[@"splinePoints"];
        XCTAssertEqual(curve.count, (uint32_t)rs.count, @"%@ curve count", name);
        double worst = 0;
        for (uint32_t i = 0; i < curve.count && i < rs.count; i++) {
            worst = fmax(worst, fabs(curve.points[i].x - [rs[i][0] doubleValue]));
            worst = fmax(worst, fabs(curve.points[i].y - [rs[i][1] doubleValue]));
        }
        XCTAssertLessThanOrEqual(worst, 1e-9, @"%@ curve differs by %g", name, worst);

        // Area, centroid, length, angle.
        XCTAssertTrue(SameFloat(BKROIAreaCm2(&s, &curve), Num(r[@"roiArea_cm2"])), @"%@ area %.9g vs %.9g", name,
                      BKROIAreaCm2(&s, &curve), Num(r[@"roiArea_cm2"]));
        BKROIPoint c = BKROICentroid(&s);
        XCTAssertTrue(NearFloat(c.x, [r[@"centroid"][0] doubleValue]), @"%@ centroid x %.10g", name, c.x);
        XCTAssertTrue(NearFloat(c.y, [r[@"centroid"][1] doubleValue]), @"%@ centroid y %.10g", name, c.y);
        if (r[@"length_mm"] && outline.count >= 2) {
            float mm = BKROILength(outline.points[0], outline.points[1], sx, sy, 0);
            float px = BKROILength(outline.points[0], outline.points[1], sx, sy, 1);
            XCTAssertTrue(SameFloat(mm, Num(r[@"length_mm"])), @"%@ length cm %.9g vs %.9g", name, mm, Num(r[@"length_mm"]));
            XCTAssertTrue(SameFloat(px, Num(r[@"length_px"])), @"%@ length px %.9g vs %.9g", name, px, Num(r[@"length_px"]));
        }
        if (r[@"angle_p1_p0_p2"] && outline.count >= 3) {
            float a = BKROIAngle(outline.points[1], outline.points[0], outline.points[2], sx, sy);
            XCTAssertTrue(SameFloat(a, Num(r[@"angle_p1_p0_p2"])), @"%@ angle %.9g vs %.9g", name, a, Num(r[@"angle_p1_p0_p2"]));
        }

        // Inside pixels (order, positions, values) and statistics.
        NSArray *locs = r[@"inside"][@"locations"], *vals = r[@"inside"][@"values"];
        NSDictionary *st = r[@"stats"];
        if (curve.count == 1) {
            int32_t x, y;
            float v = BKROIPointValue(curve.points[0], image, W, H, &x, &y);
            XCTAssertEqual([r[@"inside"][@"count"] intValue], 1, @"%@", name);
            XCTAssertTrue(SameFloat(v, Num(vals[0])), @"%@ point value", name);
            XCTAssertEqual(x, [locs[0][0] intValue]); XCTAssertEqual(y, [locs[0][1] intValue]);
            // One pixel: mean = total = min = max = value, SD NaN (recorded).
            XCTAssertTrue(SameFloat(v, Num(st[@"mean"])) && SameFloat(v, Num(st[@"total"])), @"%@", name);
            XCTAssertTrue(isnan(Num(st[@"dev"])), @"%@ dev", name);
        } else {
            BKROIRunList runs = BKROIInsideRuns(curve.points, curve.count, W, H);
            uint32_t k = 0, bad = 0;
            NSString *firstBad = nil;
            for (uint32_t i = 0; i < runs.count; i++)
                for (int32_t x = runs.runs[i].x0; x <= runs.runs[i].x1; x++, k++) {
                    if (k >= locs.count) { bad++; continue; }
                    if ([locs[k][0] intValue] != x || [locs[k][1] intValue] != runs.runs[i].y) {
                        if (!firstBad) firstBad = [NSString stringWithFormat:@"#%u mine %d,%d recorded %@,%@", k, x, runs.runs[i].y, locs[k][0], locs[k][1]];
                        bad++;
                    }
                }
            XCTAssertEqual(k, (uint32_t)locs.count, @"%@ inside count", name);
            XCTAssertEqual(bad, 0u, @"%@ inside pixels at other places (first: %@)", name, firstBad);
            BKROIStats S = BKROIStatsOfRuns(&runs, image, W, H);
            XCTAssertTrue(SameFloat(S.mean, Num(st[@"mean"])), @"%@ mean %.9g vs %.9g", name, S.mean, Num(st[@"mean"]));
            XCTAssertTrue(SameFloat(S.total, Num(st[@"total"])), @"%@ total %.9g vs %.9g", name, S.total, Num(st[@"total"]));
            XCTAssertTrue(NearFloat(S.dev, Num(st[@"dev"])), @"%@ dev %.9g vs %.9g", name, S.dev, Num(st[@"dev"]));
            XCTAssertTrue(SameFloat(S.min, Num(st[@"min"])), @"%@ min", name);
            XCTAssertTrue(SameFloat(S.max, Num(st[@"max"])), @"%@ max", name);
            BKROIRunListFree(&runs);
        }

        // Inside test on the recorder's probe grid. A probe lying ON the outline (within 1e-9 pixel of an
        // outline edge) may differ: there the answer depends on the last binary digit of the curve, which
        // the old build's fast maths set by its own arithmetic order (curves agree to ~1e-14 pixel).
        if (curve.count > 1) {
            NSMutableSet *hits = [NSMutableSet set];
            for (NSArray *h in r[@"isInROI_hits"]) [hits addObject:[NSString stringWithFormat:@"%g,%g", [h[0] doubleValue], [h[1] doubleValue]]];
            NSUInteger differing = 0, onOutline = 0;
            for (float y = -2; y <= H + 2; y += 1.5f)
                for (float x = -2; x <= W + 2; x += 1.5f) {
                    BOOL mine = BKROIContainsPoint(kind, curve.points, curve.count, x, y) != 0;
                    BOOL old = [hits containsObject:[NSString stringWithFormat:@"%g,%g", (double)x, (double)y]];
                    if (mine == old) continue;
                    if ([self pixelOf:x :y onCurve:&curve]) { onOutline++; continue; }
                    differing++;
                    NSLog(@"BKROI probe %@ %g,%g mine %d recorded %d", name, (double)x, (double)y, mine, old);
                }
            XCTAssertEqual(differing, 0u, @"%@ inside-test answers differing", name);
            if (onOutline) NSLog(@"BKROI %@: %lu probe(s) exactly on the outline answered differently (allowed)", name, (unsigned long)onOutline);
        }
        BKROIPointListFree(&curve);
        BKROIPointListFree(&outline);
    }
    free(image);
}

// Is the whole-pixel point of probe (x, y) within 1e-9 pixel of an edge of the curve?
- (BOOL)pixelOf:(float)x :(float)y onCurve:(const BKROIPointList *)c
{
    double px = (double)(long)x, py = (double)(long)y;
    for (uint32_t i = 0; i < c->count; i++) {
        BKROIPoint a = c->points[i], b = c->points[(i + 1) % c->count];
        double dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
        double t = len2 > 0 ? ((px - a.x) * dx + (py - a.y) * dy) / len2 : 0;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        double ex = a.x + t * dx - px, ey = a.y + t * dy - py;
        if (ex * ex + ey * ey <= 1e-18) return YES;
    }
    return NO;
}

// Smaller checks that do not need the recording.
- (void)testBasics
{
    BKROIPoint sq[4] = { {0, 0}, {10, 0}, {10, 10}, {0, 10} };
    XCTAssertEqualWithAccuracy(BKROIPolygonAreaPixels(sq, 4), 100, 0);
    XCTAssertEqualWithAccuracy(BKROILength(sq[0], sq[2], 1, 1, 1), sqrtf(200), 1e-4);
    XCTAssertEqualWithAccuracy(BKROIAngle(sq[1], sq[0], sq[3], 1, 1), 90, 1e-4);
    // A 10 x 10 square from (2,2): rows 2..12 (11 rows) of 11 pixels with this rule.
    BKROIPoint q[4] = { {2, 2}, {12, 2}, {12, 12}, {2, 12} };
    BKROIRunList runs = BKROIInsideRuns(q, 4, 32, 32);
    XCTAssertGreaterThan(runs.count, 0u);
    XCTAssertEqual(runs.runs[0].x0, 2); XCTAssertEqual(runs.runs[0].x1, 12);
    BKROIRunListFree(&runs);
}

// Plan step 7 remainder (2026-11-16): brush masks, colour pixels, statistics of values, moments, curve pieces.
- (void)testBrushColourMomentsPieces
{
    // A 4 x 3 mask placed at (-1, 1) on a 4 x 4 image: column 0 of the mask is off the image.
    const uint8_t mask[12] = { 1, 1, 0, 1,
                               0, 0, 0, 0,
                               1, 1, 1, 1 };
    BKROIRunList runs = BKROIMaskRuns(mask, 4, 3, -1, 1, 4, 4);
    XCTAssertEqual(runs.count, 3u);
    XCTAssertEqual(runs.runs[0].y, 1); XCTAssertEqual(runs.runs[0].x0, 0); XCTAssertEqual(runs.runs[0].x1, 0);
    XCTAssertEqual(runs.runs[1].y, 1); XCTAssertEqual(runs.runs[1].x0, 2); XCTAssertEqual(runs.runs[1].x1, 2);
    XCTAssertEqual(runs.runs[2].y, 3); XCTAssertEqual(runs.runs[2].x0, 0); XCTAssertEqual(runs.runs[2].x1, 2);
    XCTAssertEqual(BKROIRunsPixelCount(&runs, 4, 4), 5u);
    XCTAssertEqual(BKROIMaskCount(mask, 4, 3), 7u);                    // area counts every painted pixel
    XCTAssertTrue(BKROIMaskContains(mask, 4, 3, -1, 1, 0.0, 1.0));
    XCTAssertTrue(BKROIMaskContains(mask, 4, 3, -1, 1, 0.9, 1.9));     // same pixel
    XCTAssertFalse(BKROIMaskContains(mask, 4, 3, -1, 1, 1.0, 1.0));    // mask (2, 0) not painted
    XCTAssertFalse(BKROIMaskContains(mask, 4, 3, -1, 1, 0.0, 2.0));    // empty mask row
    XCTAssertFalse(BKROIMaskContains(mask, 4, 3, -1, 1, 3.0, 1.0));    // right of the mask

    // Float image values 0..15 (value = y * 4 + x): run values in run order, with locations.
    float image[16];
    for (int k = 0; k < 16; k++) image[k] = (float)k;
    float v[5], loc[10];
    XCTAssertEqual(BKROIValuesOfRuns(&runs, image, NULL, 4, 4, v, loc), 5u);
    XCTAssertEqual(v[0], 4.0f); XCTAssertEqual(v[1], 6.0f); XCTAssertEqual(v[2], 12.0f); XCTAssertEqual(v[4], 14.0f);
    XCTAssertEqual(loc[2], 2.0f); XCTAssertEqual(loc[3], 1.0f);
    // Statistics of values = statistics of runs, to the bit.
    BKROIStats a = BKROIStatsOfRuns(&runs, image, 4, 4), b = BKROIStatsOfValues(v, 5);
    XCTAssertEqual(a.count, b.count); XCTAssertEqual(a.mean, b.mean); XCTAssertEqual(a.total, b.total);
    XCTAssertEqual(a.dev, b.dev); XCTAssertEqual(a.min, b.min); XCTAssertEqual(a.max, b.max);

    // Colour pixels (A, R, G, B): the average of R, G, B - alpha never counts (the fixed old bug).
    uint8_t argb[16 * 4];
    for (int k = 0; k < 16; k++) { argb[4 * k] = 255; argb[4 * k + 1] = 30; argb[4 * k + 2] = 60; argb[4 * k + 3] = (uint8_t)(90 + k); }
    XCTAssertEqualWithAccuracy(BKROIColorValue(argb), 60.0f, 1e-6);
    XCTAssertEqual(BKROIValuesOfRuns(&runs, NULL, argb, 4, 4, v, NULL), 5u);
    XCTAssertEqualWithAccuracy(v[0], (30 + 60 + 94) / 3.0f, 1e-5);   // pixel 4
    BKROIRunListFree(&runs);

    // Moments: symmetric values -> skewness 0; known kurtosis for 1, 2, 3, 4, 5 with the (n - 1) rule:
    // m2 = 10/4, m4 = 34/4 -> 8.5 / 6.25 - 3 = -1.64.
    float sym[5] = { 1, 2, 3, 4, 5 };
    double sk = 1, ku = 1;
    BKROIMoments(sym, 5, 3.0, &sk, &ku);
    XCTAssertEqualWithAccuracy(sk, 0.0, 1e-12);
    XCTAssertEqualWithAccuracy(ku, -1.64, 1e-12);
    BKROIMoments(sym, 1, 1.0, &sk, &ku);
    XCTAssertEqual(sk, 0.0); XCTAssertEqual(ku, 0.0);

    // Curve pieces: a smoothed closed square - every curve point names a piece 0..3 in order, the curve is
    // the same as BKROICurve's; an unsmoothed outline gives no pieces.
    BKROIPoint sq[4] = { { 10, 10 }, { 40, 10 }, { 40, 40 }, { 10, 40 } };
    BKROIShape s = { BKROIKindClosedPolygon, sq, 4, 0, 0, 0, 0, 1, 1, 1, 0 };
    int32_t *pieces = NULL;
    BKROIPointList c1 = BKROICurve(&s, 1), c2 = BKROICurveWithPieces(&s, 1, &pieces);
    XCTAssertEqual(c1.count, c2.count);
    XCTAssertTrue(pieces != NULL);
    for (uint32_t k = 0; pieces && k < c2.count; k++) {
        XCTAssertEqual(c1.points[k].x, c2.points[k].x);
        XCTAssertTrue(pieces[k] >= 0 && pieces[k] <= 3);
        if (k) XCTAssertTrue(pieces[k] >= pieces[k - 1]);
    }
    XCTAssertEqual(pieces[0], 0);
    XCTAssertEqual(pieces[c2.count - 1], 3);
    free(pieces);
    BKROIPointListFree(&c1); BKROIPointListFree(&c2);
    s.smooth = 0;
    BKROIPointList c3 = BKROICurveWithPieces(&s, 1, &pieces);
    XCTAssertTrue(pieces == NULL);
    BKROIPointListFree(&c3);
}

@end
