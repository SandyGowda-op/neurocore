#!/bin/sh
# Run the four directed hazard tests against whatever RTL is currently in src/.
# Layout assumed (riscv_accelerator_upgrade/):
#   src/                         all RTL (.sv/.v)
#   verification/tb/             testbenches, incl. hazard_directed_tb.sv (+ gold_arrays.svh)
#   "mem files"/                 your .mem files (never modified by this script)
#   "mem files"/directed/        t1.mem..t4.mem from gen_progs.py
#   scripts/                     this script + gen_progs.py
# Each test runs in its own scratch dir under build/directed/ with its own copy
# of the .mem files, so your real instruction_memory.mem is never touched.
# instr_mem.sv loads "mem files/instruction_memory.mem" (relative path), so the scratch
# dir gets its own "mem files/" folder.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src"; TB="$ROOT/verification/tb"; MEM="$ROOT/mem files"; PROGS="$MEM/directed"
for t in 1 2 3 4; do
  W="$ROOT/build/directed/t$t"; rm -rf "$W"; mkdir -p "$W"
  # instr_mem does $readmemh("mem files/instruction_memory.mem"), a path relative to the
  # simulator's working dir, so recreate "mem files/" inside the scratch dir. Copies also
  # go in the scratch root in case other modules load their .mem files by bare name.
  mkdir -p "$W/mem files"
  cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null || true
  cp "$MEM"/*.mem "$W"/ 2>/dev/null || true
  cp "$PROGS/t$t.mem" "$W/mem files/instruction_memory.mem"
  cp "$PROGS/t$t.mem" "$W/instruction_memory.mem"
  # packages first (iverilog needs them defined before use)
  PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
  REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
  ( cd "$W" && iverilog -g2012 -D__ICARUS__ -I "$SRC" -I "$TB" -I "$ROOT/verification" \
      -s hazard_directed_tb -o sim.vvp $PKGS $REST "$TB/hazard_directed_tb.sv" )
  ( cd "$W" && vvp sim.vvp +TEST=$t | grep -E "PASS|FAIL|====" )
done