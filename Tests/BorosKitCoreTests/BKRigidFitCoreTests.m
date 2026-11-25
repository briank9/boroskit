// Tests for BKRigidFitCore (Horn's point-based rigid registration).
//
// Original BorosKit code written for this project; contains no third-party code.
//
// kVTKHorn4 / kVTKHorn6 were RECORDED FROM THE CLASSIC ENGINE (2026-11-24, vtk-data): a scratch harness linked
// Boros' VTK 8.2 build and printed vtkLandmarkTransform (rigid body mode, as HornRegistration used it) matrices
// for these points (the 4-point set is the one in HornRegistration's old commented-out self test). Agreement
// measured: 1e-12. Numbers only - no VTK code is part of BorosKit.

#import <XCTest/XCTest.h>
#include "BKRigidFitCore.h"

@interface BKRigidFitCoreTests : XCTestCase
@end

static const BKVec3d kModel[6] = { {0, 0, 0}, {10, 0, 0}, {10, 10, 0}, {0, 10, 0}, {3, 7, 12}, {-4, 2, 5} };
static const BKVec3d kSensor[6] = { {5, 0, 0}, {5, 10, 0}, {5, 10, 11}, {5, 0, 10}, {17, 3, 7}, {9, -4, 2} };
// Rows of the 3x4 matrix [R | T].
static const double kVTKHorn4[12] = { 0.000000000000, -0.000000000000, 1.000000000000, 5.000000000000,
    0.999702690643, -0.024382992455, -0.000000000000, 0.123401509058,
    0.024382992455, 0.999702690643, 0.000000000000, 0.129571584511 };
static const double kVTKHorn6[12] = { 0.022975738803, 0.018291203977, 0.999568680624, 4.673391412800,
    0.999520939334, -0.021158894322, -0.022587452784, 0.167782797555,
    0.020736616375, 0.999608790001, -0.018768582610, 0.156069213868 };

static double BKTestResidual(const BKVec3d *s, const BKVec3d *t, int n, const double R[9], const double T[3])
{
    double sum = 0;
    for (int i = 0; i < n; i++)
    {
        double m[3];
        for (int r = 0; r < 3; r++) m[r] = R[r * 3] * s[i].x + R[r * 3 + 1] * s[i].y + R[r * 3 + 2] * s[i].z + T[r];
        sum += (m[0] - t[i].x) * (m[0] - t[i].x) + (m[1] - t[i].y) * (m[1] - t[i].y) + (m[2] - t[i].z) * (m[2] - t[i].z);
    }
    return sum;
}

static void BKTestRotation(double axisX, double axisY, double axisZ, double angle, double R[9])
{
    double l = sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ), x = axisX / l, y = axisY / l, z = axisZ / l;
    double c = cos(angle), s = sin(angle), C = 1 - c;
    double M[9] = { x * x * C + c, x * y * C - z * s, x * z * C + y * s,
                    y * x * C + z * s, y * y * C + c, y * z * C - x * s,
                    z * x * C - y * s, z * y * C + x * s, z * z * C + c };
    for (int i = 0; i < 9; i++) R[i] = M[i];
}

@implementation BKRigidFitCoreTests

- (void)testMatchesRecordedVTK
{
    double R[9], T[3];
    XCTAssertEqual(BKRigidFitHorn(kModel, kSensor, 4, R, T, NULL), 0);
    for (int r = 0; r < 3; r++)
    {
        for (int c = 0; c < 3; c++) XCTAssertEqualWithAccuracy(R[r * 3 + c], kVTKHorn4[r * 4 + c], 1e-9);
        XCTAssertEqualWithAccuracy(T[r], kVTKHorn4[r * 4 + 3], 1e-9);
    }
    BKRigidFitHorn(kModel, kSensor, 6, R, T, NULL);
    for (int r = 0; r < 3; r++)
    {
        for (int c = 0; c < 3; c++) XCTAssertEqualWithAccuracy(R[r * 3 + c], kVTKHorn6[r * 4 + c], 1e-9);
        XCTAssertEqualWithAccuracy(T[r], kVTKHorn6[r * 4 + 3], 1e-9);
    }
}

- (void)testExactRecovery
{
    // Points moved by a known rotation + shift are mapped back exactly.
    BKVec3d src[7] = { {1, 2, 3}, {-4, 0.5, 9}, {12, -7, 1}, {0, 0, 0}, {5, 5, -5}, {-3, 8, 2}, {7, 1, 6} }, dst[7];
    double Rk[9], Tk[3] = { 12.5, -40, 3.25 };
    BKTestRotation(0.3, -1, 0.7, 2.4, Rk);
    for (int i = 0; i < 7; i++)
        dst[i] = BKV3d(Rk[0] * src[i].x + Rk[1] * src[i].y + Rk[2] * src[i].z + Tk[0],
                       Rk[3] * src[i].x + Rk[4] * src[i].y + Rk[5] * src[i].z + Tk[1],
                       Rk[6] * src[i].x + Rk[7] * src[i].y + Rk[8] * src[i].z + Tk[2]);
    double R[9], T[3], rms;
    BKRigidFitHorn(src, dst, 7, R, T, &rms);
    for (int i = 0; i < 9; i++) XCTAssertEqualWithAccuracy(R[i], Rk[i], 1e-10);
    for (int i = 0; i < 3; i++) XCTAssertEqualWithAccuracy(T[i], Tk[i], 1e-9);
    XCTAssertLessThan(rms, 1e-9);
}

- (void)testLeastSquaresAndProperRotation
{
    // For noisy points the answer is a proper rotation (det +1, orthonormal) and any small extra turn or shift
    // makes the fit worse.
    double R[9], T[3];
    BKRigidFitHorn(kModel, kSensor, 6, R, T, NULL);
    double det = R[0] * (R[4] * R[8] - R[5] * R[7]) - R[1] * (R[3] * R[8] - R[5] * R[6]) + R[2] * (R[3] * R[7] - R[4] * R[6]);
    XCTAssertEqualWithAccuracy(det, 1, 1e-12);
    for (int a = 0; a < 3; a++)
        for (int b = 0; b < 3; b++)
        {
            double d = R[a * 3] * R[b * 3] + R[a * 3 + 1] * R[b * 3 + 1] + R[a * 3 + 2] * R[b * 3 + 2];
            XCTAssertEqualWithAccuracy(d, a == b, 1e-12);
        }
    double best = BKTestResidual(kModel, kSensor, 6, R, T);
    for (int axis = 0; axis < 3; axis++)
        for (int sign = -1; sign <= 1; sign += 2)
        {
            double D[9], R2[9], T2[3] = { T[0], T[1], T[2] };
            BKTestRotation(axis == 0, axis == 1, axis == 2, sign * 1e-3, D);
            for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++)
                R2[r * 3 + c] = D[r * 3] * R[c] + D[r * 3 + 1] * R[3 + c] + D[r * 3 + 2] * R[6 + c];
            XCTAssertGreaterThan(BKTestResidual(kModel, kSensor, 6, R2, T2), best);
            T2[axis] += sign * 1e-3;
            XCTAssertGreaterThan(BKTestResidual(kModel, kSensor, 6, R, T2), best);
        }
}

- (void)testDegenerateInput
{
    double R[9], T[3];
    // One point: no rotation, only the shift.
    BKVec3d a = { 1, 2, 3 }, b = { -2, 5, 10 };
    BKRigidFitHorn(&a, &b, 1, R, T, NULL);
    for (int i = 0; i < 9; i++) XCTAssertEqualWithAccuracy(R[i], i % 4 == 0, 1e-12);
    XCTAssertEqualWithAccuracy(T[0], -3, 1e-12);
    XCTAssertEqualWithAccuracy(T[1], 3, 1e-12);
    XCTAssertEqualWithAccuracy(T[2], 7, 1e-12);
    // Points on one line (x axis -> y axis): the smallest rotation, 90 degrees about z.
    BKVec3d s[3] = { {0, 0, 0}, {1, 0, 0}, {3, 0, 0} }, t[3] = { {0, 0, 0}, {0, 1, 0}, {0, 3, 0} };
    double rms;
    BKRigidFitHorn(s, t, 3, R, T, &rms);
    XCTAssertLessThan(rms, 1e-9);
    const double expect[9] = { 0, -1, 0, 1, 0, 0, 0, 0, 1 };
    for (int i = 0; i < 9; i++) XCTAssertEqualWithAccuracy(R[i], expect[i], 1e-9);
    XCTAssertEqual(BKRigidFitHorn(s, t, 0, R, T, NULL), -1);
}

- (void)testEigenSolver
{
    // A symmetric matrix with known eigenvalues 7, 3, -1, -2 (diag in a rotated basis).
    double Q[16], D[4] = { 3, -2, 7, -1 }, A[16] = { 0 };
    // Q = an orthonormal basis built from two plane rotations.
    double c = cos(0.7), s = sin(0.7), c2 = cos(-1.1), s2 = sin(-1.1);
    double Q1[16] = { c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    double Q2[16] = { 1, 0, 0, 0, 0, c2, 0, -s2, 0, 0, 1, 0, 0, s2, 0, c2 };
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++)
    { double v = 0; for (int k = 0; k < 4; k++) v += Q1[i * 4 + k] * Q2[k * 4 + j]; Q[i * 4 + j] = v; }
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++)
        for (int k = 0; k < 4; k++) A[i * 4 + j] += Q[i * 4 + k] * D[k] * Q[j * 4 + k];
    double values[4], vectors[16];
    BKSymmetricEigen4(A, values, vectors);
    const double sorted[4] = { 7, 3, -1, -2 };
    for (int k = 0; k < 4; k++)
    {
        XCTAssertEqualWithAccuracy(values[k], sorted[k], 1e-12);
        // A v = lambda v
        for (int i = 0; i < 4; i++)
        {
            double av = 0;
            for (int j = 0; j < 4; j++) av += A[i * 4 + j] * vectors[k * 4 + j];
            XCTAssertEqualWithAccuracy(av, values[k] * vectors[k * 4 + i], 1e-12);
        }
    }
}

@end
