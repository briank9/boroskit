// BorosKitCore: BKRigidFitCore - see BKRigidFitCore.h.
// Original BorosKit code written for this project; contains no third-party code.
// Boros 6 (2026-11-24, vtk-data).

#include "BKRigidFitCore.h"
#include <math.h>
#include <string.h>

void BKSymmetricEigen4(const double a[16], double values[4], double vectors[16])
{
    double A[4][4], V[4][4];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) { A[i][j] = 0.5 * (a[i * 4 + j] + a[j * 4 + i]); V[i][j] = (i == j); }

    // Cyclic Jacobi: each step zeroes one off-diagonal pair (p, q) with a plane rotation; repeat the sweep until
    // the off-diagonal part is negligible. Converges quadratically for symmetric matrices.
    for (int sweep = 0; sweep < 64; sweep++)
    {
        double off = 0, diag = 0;
        for (int i = 0; i < 4; i++) { diag += A[i][i] * A[i][i]; for (int j = i + 1; j < 4; j++) off += A[i][j] * A[i][j]; }
        if (off <= 1e-30 * (diag + 1e-300)) break;
        for (int p = 0; p < 3; p++)
            for (int q = p + 1; q < 4; q++)
            {
                if (A[p][q] == 0) continue;
                // Rotation angle that zeroes A[p][q]: tan(2 phi) = 2 A[p][q] / (A[q][q] - A[p][p]).
                double theta = (A[q][q] - A[p][p]) / (2 * A[p][q]);
                double tt = (theta >= 0 ? 1.0 : -1.0) / (fabs(theta) + sqrt(theta * theta + 1));
                double c = 1 / sqrt(tt * tt + 1), s = tt * c;
                for (int k = 0; k < 4; k++)
                {
                    double akp = A[k][p], akq = A[k][q];
                    A[k][p] = c * akp - s * akq;
                    A[k][q] = s * akp + c * akq;
                }
                for (int k = 0; k < 4; k++)
                {
                    double apk = A[p][k], aqk = A[q][k];
                    A[p][k] = c * apk - s * aqk;
                    A[q][k] = s * apk + c * aqk;
                }
                for (int k = 0; k < 4; k++)
                {
                    double vkp = V[k][p], vkq = V[k][q];
                    V[k][p] = c * vkp - s * vkq;
                    V[k][q] = s * vkp + c * vkq;
                }
            }
    }
    // Sort descending (stable order for equal values: lower index first).
    int order[4] = { 0, 1, 2, 3 };
    for (int i = 0; i < 4; i++)
        for (int j = i + 1; j < 4; j++)
            if (A[order[j]][order[j]] > A[order[i]][order[i]]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
    for (int k = 0; k < 4; k++)
    {
        int c = order[k];
        values[k] = A[c][c];
        double len = 0;
        for (int i = 0; i < 4; i++) len += V[i][c] * V[i][c];
        len = sqrt(len);
        for (int i = 0; i < 4; i++) vectors[k * 4 + i] = V[i][c] / len;
    }
}

int BKRigidFitHorn(const BKVec3d *source, const BKVec3d *target, int n, double R[9], double T[3], double *rmsOut)
{
    for (int i = 0; i < 9; i++) R[i] = (i % 4 == 0);
    T[0] = T[1] = T[2] = 0;
    if (rmsOut) *rmsOut = 0;
    if (source == NULL || target == NULL || n < 1) return -1;

    // 1. Centres of both point sets.
    BKVec3d cs = BKV3d(0, 0, 0), ct = BKV3d(0, 0, 0);
    for (int i = 0; i < n; i++) { cs = BKV3dAdd(cs, source[i]); ct = BKV3dAdd(ct, target[i]); }
    cs = BKV3dDiv(cs, n); ct = BKV3dDiv(ct, n);

    // 2. Sum of products S[a][b] = sum over points of source_a * target_b (both centred).
    double S[3][3] = { { 0 } };
    for (int i = 0; i < n; i++)
    {
        BKVec3d s = BKV3dSub(source[i], cs), t = BKV3dSub(target[i], ct);
        double sv[3] = { s.x, s.y, s.z }, tv[3] = { t.x, t.y, t.z };
        for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) S[a][b] += sv[a] * tv[b];
    }

    // 3. Horn's symmetric 4x4 matrix; the quaternion (w, x, y, z) of the best rotation is the eigenvector of its
    // largest eigenvalue.
    double Sxx = S[0][0], Sxy = S[0][1], Sxz = S[0][2], Syx = S[1][0], Syy = S[1][1], Syz = S[1][2];
    double Szx = S[2][0], Szy = S[2][1], Szz = S[2][2];
    double N[16] = {
        Sxx + Syy + Szz, Syz - Szy,        Szx - Sxz,        Sxy - Syx,
        Syz - Szy,       Sxx - Syy - Szz,  Sxy + Syx,        Szx + Sxz,
        Szx - Sxz,       Sxy + Syx,       -Sxx + Syy - Szz,  Syz + Szy,
        Sxy - Syx,       Szx + Sxz,        Syz + Szy,       -Sxx - Syy + Szz };
    double values[4], vectors[16];
    BKSymmetricEigen4(N, values, vectors);

    // 4. When several eigenvalues tie for the largest (degenerate input, see the header), every unit vector in
    // their span fits equally well: take the one closest to "no rotation" (the projection of (1,0,0,0)).
    double scale = 0;
    for (int k = 0; k < 4; k++) if (fabs(values[k]) > scale) scale = fabs(values[k]);
    double tol = 1e-9 * scale + 1e-300;
    double q[4] = { 0, 0, 0, 0 };
    int tied = 0;
    for (int k = 0; k < 4 && values[0] - values[k] <= tol; k++) tied++;
    if (tied > 1)
    {
        for (int k = 0; k < tied; k++)
            for (int i = 0; i < 4; i++) q[i] += vectors[k * 4 + 0] * vectors[k * 4 + i];
        double len = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        if (len > 1e-12) for (int i = 0; i < 4; i++) q[i] /= len;
        else memcpy(q, vectors, sizeof(q));
    }
    else memcpy(q, vectors, sizeof(q));
    if (q[0] < 0) for (int i = 0; i < 4; i++) q[i] = -q[i];   // same rotation; keeps the output repeatable

    // 5. Quaternion -> rotation matrix (row-major), then the shift.
    double w = q[0], x = q[1], y = q[2], z = q[3];
    R[0] = w * w + x * x - y * y - z * z; R[1] = 2 * (x * y - w * z);         R[2] = 2 * (x * z + w * y);
    R[3] = 2 * (y * x + w * z);         R[4] = w * w - x * x + y * y - z * z; R[5] = 2 * (y * z - w * x);
    R[6] = 2 * (z * x - w * y);         R[7] = 2 * (z * y + w * x);         R[8] = w * w - x * x - y * y + z * z;
    T[0] = ct.x - (R[0] * cs.x + R[1] * cs.y + R[2] * cs.z);
    T[1] = ct.y - (R[3] * cs.x + R[4] * cs.y + R[5] * cs.z);
    T[2] = ct.z - (R[6] * cs.x + R[7] * cs.y + R[8] * cs.z);

    if (rmsOut)
    {
        double sum = 0;
        for (int i = 0; i < n; i++)
        {
            const BKVec3d p = source[i];
            BKVec3d m = BKV3d(R[0] * p.x + R[1] * p.y + R[2] * p.z + T[0],
                              R[3] * p.x + R[4] * p.y + R[5] * p.z + T[1],
                              R[6] * p.x + R[7] * p.y + R[8] * p.z + T[2]);
            BKVec3d d = BKV3dSub(m, target[i]);
            sum += BKV3dDot(d, d);
        }
        *rmsOut = sqrt(sum / n);
    }
    return 0;
}
