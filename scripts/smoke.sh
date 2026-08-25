#!/usr/bin/env bash
# Headless end-to-end smokes. Run inside the dev shell: `nix develop -c scripts/smoke.sh`.
#
# Builds the viewer + sketches + step library into zig-out-debug. Without
# -Drelease, zig master's standardOptimizeOption builds Debug — the only mode
# in which the viewer's process allocator is a leak-checking DebugAllocator,
# which is what makes the leak assertions below meaningful. Drives each
# scenario under Xvfb (llvmpipe) and asserts:
#   * the deterministic stat lines the scenarios must print,
#   * no sokol panics/errors, no allocator leak reports, no dropped frames.
# Exit status is non-zero on any mismatch. Timing/throughput fields are not
# compared (they vary); huge-page counters are environmental and not asserted.
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX=zig-out-debug
LOGS="${SMOKE_LOGS:-/tmp/vertex-smoke-$$}"
mkdir -p "$LOGS"
echo "building debug artifacts into $PREFIX (logs: $LOGS)"
zig build --prefix "$PREFIX"
zig build step -Dsketch=smooth --prefix "$PREFIX"
zig build --prefix "$PREFIX" --summary all 2>&1 | grep -q " debug native" || { echo "expected a Debug build (do not pass -Drelease)"; exit 1; }

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
expect() { # expect <log> <regex>
  if grep -qE -- "$2" "$1"; then echo "  ok: $2"; else fail "$1 lacks /$2/"; fi
}
forbid() { # forbid <log> <regex> <label>
  if grep -qiE -- "$2" "$1"; then fail "$3 in $1:"; grep -iE -- "$2" "$1" | head -3; else echo "  ok: no $3"; fi
}

# run <name> <frames> "<viewer env>" [sketch] ["<sketch env>"]
run() {
  local name=$1 frames=$2 venv=$3 sketch=${4:-} senv=${5:-}
  local sock="/tmp/vxs-$name-$$.sock" log="$LOGS/$name.log"
  rm -f "$sock"
  echo "== $name"
  env VERTEX_SOCK="$sock" VERTEX_EXIT_AFTER_FRAMES="$frames" $venv \
    xvfb-run -a -s '-screen 0 1400x900x24' "./$PREFIX/bin/vertex-view" >"$log" 2>&1 &
  local vpid=$!
  for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.1; done
  if [ -n "$sketch" ]; then
    if ! env $senv VERTEX_SOCK="$sock" "./$PREFIX/bin/$sketch" >"$LOGS/$name.sketch" 2>&1; then
      fail "$sketch exited non-zero"; tail -5 "$LOGS/$name.sketch"
    fi
  fi
  wait "$vpid" || fail "viewer exited non-zero for $name"
  rm -f "$sock"
  forbid "$log" 'panic|\[error\]|dropping' 'sokol error'
  # DebugAllocator reports look like: error(gpa): memory address 0x... leaked:
  forbid "$log" 'memory address 0x[0-9a-f]+ leaked|error\(gpa\)' 'allocator leak report'
  [ -n "$sketch" ] && forbid "$LOGS/$name.sketch" 'memory address 0x[0-9a-f]+ leaked|error\(gpa\)' 'sketch leak report'
  return 0
}

run current 3000 "VERTEX_PICK_PROBE=700,450" sketch-current
expect "$LOGS/current.log" 'vertex-view: structures=4 frames=25 blobs=83'
expect "$LOGS/current.log" 'vertex-view: probe structure=sphere kind=face element=693'

run churn 6000 "" sketch-churn
expect "$LOGS/churn.log" 'vertex-view: structures=1 frames=401 blobs=802'

run stepper 1500 "VERTEX_STEP_LIB=$PREFIX/lib/libstep-smooth.so VERTEX_STEP_AUTORUN=1"
expect "$LOGS/stepper.log" 'vertex-view: stepper steps=60 state=finished reloads=0 leaks=0'
expect "$LOGS/stepper.log" 'vertex-view: structures=1 frames=61 blobs=123'

run stress 400 "" sketch-stress "VERTEX_STRESS_SHARED=1"
expect "$LOGS/stress.log" 'vertex-view: structures=1 frames=41 blobs=42'
expect "$LOGS/stress.log" 'mapped_bytes=480960480'

if [ "$failures" -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED: $failures"; exit 1; fi
