#!/usr/bin/env python3
"""Concatenates the JSON lines of a benchmark run into bench/baseline.jsonl.

Takes the captured output of each benchmark executable and writes them, sorted,
as the new baseline. Sorted so that the file's diff shows what moved rather than
what order the build happened to run things in.

    zig build bench-baseline
"""
import sys

def main(argv):
    lines = []
    for path in argv[1:]:
        with open(path) as f:
            lines += [l.strip() for l in f if l.strip().startswith("{")]
    lines.sort()
    with open("bench/baseline.jsonl", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"bench/baseline.jsonl: {len(lines)} measurements")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
