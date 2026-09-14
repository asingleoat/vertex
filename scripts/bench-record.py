#!/usr/bin/env python3
"""Concatenates the JSON lines of a benchmark run into bench/baseline.jsonl.

Takes the captured output of each benchmark executable and writes them, sorted,
as the new baseline. Sorted so that the file's diff shows what moved rather than
what order the build happened to run things in.

    zig build bench-baseline
"""
import json
import os
import platform
import subprocess
import sys


def host_tag():
    override = os.environ.get("BENCH_HOST")
    if override:
        return override
    machine = platform.machine()
    # The project's portability table says aarch64-darwin; platform says arm64.
    if machine == "arm64":
        machine = "aarch64"
    return f"{cpu_name()} / {machine}-{platform.system().lower()}"


def cpu_name():
    system = platform.system()
    try:
        if system == "Darwin":
            out = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        elif system == "Linux":
            with open("/proc/cpuinfo") as f:
                for line in f:
                    for key in ("model name", "Model", "Hardware"):
                        if line.startswith(key):
                            value = line.split(":", 1)[1].strip()
                            if value:
                                return value
    except (OSError, subprocess.SubprocessError):
        pass
    return platform.processor() or platform.machine() or "unknown"


def main(argv):
    host = host_tag()
    lines = []
    for path in argv[1:]:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                record = json.loads(line)
                record["host"] = host
                lines.append(json.dumps(record, separators=(",", ":")))
    lines.sort()
    with open("bench/baseline.jsonl", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"bench/baseline.jsonl: {len(lines)} measurements on {host!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
