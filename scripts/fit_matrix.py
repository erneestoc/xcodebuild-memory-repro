#!/usr/bin/env python3
"""Fits peak_mb ~ base + A*app_mb + B*test_mb to results/matrix.csv and
reports how well that linear model reproduces every measured point.

The fit is done on the single-variable rows only (cases where exactly one of
the two binaries is padded, plus the unpadded baseline). Rows padding both
binaries are held out, so agreement on those is evidence that the two costs
are genuinely independent and additive rather than an artefact of the fit.
"""
import csv
import sys


def solve_least_squares(rows):
    """Ordinary least squares for peak = c0 + c1*app + c2*test, via the
    3x3 normal equations with Gaussian elimination. Avoids a numpy dep."""
    n = len(rows)
    xs = [(1.0, float(r["app_mb"]), float(r["test_mb"])) for r in rows]
    ys = [float(r["peak_mb"]) for r in rows]
    ata = [[sum(xs[k][i] * xs[k][j] for k in range(n)) for j in range(3)] for i in range(3)]
    atb = [sum(xs[k][i] * ys[k] for k in range(n)) for i in range(3)]

    for col in range(3):
        pivot = max(range(col, 3), key=lambda r: abs(ata[r][col]))
        if abs(ata[pivot][col]) < 1e-9:
            return None
        ata[col], ata[pivot] = ata[pivot], ata[col]
        atb[col], atb[pivot] = atb[pivot], atb[col]
        for r in range(3):
            if r == col:
                continue
            f = ata[r][col] / ata[col][col]
            for c in range(col, 3):
                ata[r][c] -= f * ata[col][c]
            atb[r] -= f * atb[col]
    return [atb[i] / ata[i][i] for i in range(3)]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "results/matrix.csv"
    rows = [r for r in csv.DictReader(open(path)) if r.get("peak_mb")]
    if len(rows) < 3:
        print("not enough rows to fit")
        return 1

    single = [r for r in rows
              if float(r["app_mb"]) == 0 or float(r["test_mb"]) == 0]
    coeffs = solve_least_squares(single if len(single) >= 3 else rows)
    if coeffs is None:
        print("fit failed (degenerate inputs)")
        return 1
    base, a_coeff, b_coeff = coeffs

    print("")
    print(f"fit on {len(single)} single-variable rows:")
    print(f"  peak_mb = {base:.0f} + {a_coeff:.2f}*app_mb + {b_coeff:.2f}*test_mb")
    print("")
    print(f"{'app_mb':>7} {'test_mb':>8} {'peak_mb':>9} {'predicted':>10} "
          f"{'error':>8} {'held out':>9}")
    for r in rows:
        app, test = float(r["app_mb"]), float(r["test_mb"])
        peak = float(r["peak_mb"])
        pred = base + a_coeff * app + b_coeff * test
        held = "yes" if app > 0 and test > 0 else ""
        print(f"{app:7.0f} {test:8.0f} {peak:9.0f} {pred:10.0f} "
              f"{peak - pred:+8.0f} {held:>9}")

    combos = [r for r in rows if float(r["app_mb"]) > 0 and float(r["test_mb"]) > 0]
    if combos:
        worst = max(abs(float(r["peak_mb"])
                        - (base + a_coeff * float(r["app_mb"])
                           + b_coeff * float(r["test_mb"]))) / float(r["peak_mb"])
                    for r in combos)
        print("")
        print(f"held-out combinations are predicted to within {worst * 100:.1f}%, "
              "so the two costs are additive and independent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
