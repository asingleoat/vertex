#!/usr/bin/env bash
# Headless end-to-end smokes. Run inside the dev shell: `nix develop -c scripts/smoke.sh`.
#
# Builds the viewer + sketches + step library into zig-out-debug. Without
# -Drelease, zig master's standardOptimizeOption builds Debug — the only mode
# in which the viewer's process allocator is a leak-checking DebugAllocator,
# which is what makes the leak assertions below meaningful. Drives each
# scenario under Xvfb (llvmpipe) on Linux and on the real display on macOS,
# which has no Xvfb — expect four windows to appear and close. Asserts:
#   * the deterministic stat lines the scenarios must print,
#   * no sokol panics/errors, no allocator leak reports, no dropped frames.
# Exit status is non-zero on any mismatch. Timing/throughput fields are not
# compared (they vary); huge-page counters are environmental and not asserted.
set -euo pipefail
cd "$(dirname "$0")/.."

# Platform differences, all of them, in one place.
#   * No Xvfb on macOS: the viewer runs on the real display.
#   * The frame cap only has to outlive each scenario's sketch. Under llvmpipe
#     frames are free-running; on a real display they are vsync-paced, so the
#     same wall-clock budget is far fewer frames.
#   * Picking is comptime-disabled off the GL backend until the CPU ray cast
#     lands (DESIGN.md, "Picking, decided 2026-08-24"), so the probe is
#     asserted to miss rather than to find a face.
if [ "$(uname -s)" = "Darwin" ]; then
  viewer_wrapper=(env)
  lib_suffix=.dylib
  picking=0
  frames_current=600 frames_churn=900 frames_stepper=600 frames_stress=400
else
  viewer_wrapper=(xvfb-run -a -s '-screen 0 1400x900x24')
  lib_suffix=.so
  picking=1
  frames_current=3000 frames_churn=6000 frames_stepper=1500 frames_stress=400
fi

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
    "${viewer_wrapper[@]}" "./$PREFIX/bin/vertex-view" >"$log" 2>&1 &
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

run current "$frames_current" "VERTEX_PICK_PROBE=700,450" sketch-current
expect "$LOGS/current.log" 'vertex-view: structures=4 frames=25 blobs=83'
if [ "$picking" = 1 ]; then
  # The expected face is display-dependent: this is the 1400x900 Xvfb value.
  expect "$LOGS/current.log" 'vertex-view: probe structure=sphere kind=face element=693'
else
  expect "$LOGS/current.log" 'vertex-view: probe miss'
fi

run churn "$frames_churn" "" sketch-churn
expect "$LOGS/churn.log" 'vertex-view: structures=1 frames=401 blobs=802'

run stepper "$frames_stepper" "VERTEX_STEP_LIB=$PREFIX/lib/libstep-smooth$lib_suffix VERTEX_STEP_AUTORUN=1"
expect "$LOGS/stepper.log" 'vertex-view: stepper steps=60 state=finished reloads=0 leaks=0'
expect "$LOGS/stepper.log" 'vertex-view: structures=1 frames=61 blobs=123'

run stress "$frames_stress" "" sketch-stress "VERTEX_STRESS_SHARED=1"
expect "$LOGS/stress.log" 'vertex-view: structures=1 frames=41 blobs=42'
expect "$LOGS/stress.log" 'mapped_bytes=480960480'

if [ "$failures" -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED: $failures"; exit 1; fi
