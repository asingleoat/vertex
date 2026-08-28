#!/usr/bin/env python3
"""Compares a benchmark run against the checked-in baseline.

Reads the JSON lines a run writes to standard output and reports every
measurement that is slower than its baseline by more than the tolerance. A
measurement missing from either side is reported too: a benchmark that stopped
running is as much a regression as one that got slower.

The tolerance defaults to 15 per cent, which is above the noise floor the
harness records: over four runs of the whole suite the spread between the
fastest and slowest reading of one measurement was 3.6 per cent at the median
and 7.5 at the ninetieth percentile. Two benchmarks sit outside that and are
listed in `unstable` below; they are reported but do not fail the run.

Takes the baseline and then one or more run files, since a run is several
executables and the build captures each separately. BENCH_TOLERANCE overrides
the fraction.

    zig build bench-check
    scripts/bench-check.py bench/baseline.jsonl run1.jsonl run2.jsonl
"""
import json
import os
import sys

# Measured to move by a fifth or more between identical runs; see the note in
# bench/lib/harness.zig. Reported, never fatal, until that is understood.
unstable = {
    "protocol/encode",
    "planar/boolean crossings in one band",
}


def load(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            r = json.loads(line)
            out[(r["name"], r["layout"], r["n"])] = r["ps"]
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    tolerance = float(os.environ.get("BENCH_TOLERANCE", "0.15"))
    base = load(argv[1])
    run = {}
    for path in argv[2:]:
        run.update(load(path))

    regressions, notes, improvements = [], [], []
    for key in sorted(base):
        if key not in run:
            regressions.append(f"  missing   {key[0]} layout={key[1]} n={key[2]}")
            continue
        before, after = base[key], run[key]
        change = (after - before) / before
        line = (f"  {change:+7.1%}  {key[0]} layout={key[1]} n={key[2]}"
                f"  {before} -> {after} ps")
        if change > tolerance:
            (notes if key[0] in unstable else regressions).append(line)
        elif change < -tolerance:
            improvements.append(line)
    for key in sorted(set(run) - set(base)):
        notes.append(f"  new       {key[0]} layout={key[1]} n={key[2]}")

    for title, rows in (("regressions", regressions), ("improvements", improvements),
                        ("noted, not fatal", notes)):
        if rows:
            print(f"{title}:")
            print("\n".join(rows))
    if not regressions:
        print(f"{len(base)} measurements, none slower than the baseline by more than {tolerance:.0%}")
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
