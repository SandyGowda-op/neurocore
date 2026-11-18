#!/bin/sh
# T6: CPU-authored descriptors + store/fetch hazard.   sh scripts/run_swdesc.sh
# Negative controls (expected to FAIL):
#   DEFS="-DNO_DESC_STORE_GUARD" sh scripts/run_swdesc.sh   -> t6c* (torn descriptor read)
#   DEFS="-DNO_STORE_FWD_FIX"    sh scripts/run_swdesc.sh   -> t6b  (stale store data)
# (the swdesc / store-forwarding fixes are already in src/; scripts/history/ holds the patches that added them)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$ROOT/src}"; TBD="$ROOT/verification/tb"; MEM="$ROOT/mem files"
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
PROGS="$ROOT/build/swdesc/progs"; mkdir -p "$PROGS" "$ROOT/results"
python3 "$ROOT/scripts/gen_swdesc_progs.py" "$PROGS" || exit 1
SUM="$ROOT/results/swdesc_summary${TAGSUFFIX}.log"; : > "$SUM"
for t in t6a t6b t6c0 t6c1 t6c2 t6c4 t6c5; do
  W="$ROOT/build/swdesc/$t"; rm -rf "$W"; mkdir -p "$W/mem files"
  cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null; cp "$MEM"/*.mem "$W"/ 2>/dev/null
  cp "$PROGS/$t.mem" "$W/mem files/instruction_memory.mem"; cp "$PROGS/$t.mem" "$W/instruction_memory.mem"
  case $t in t6a) P=+TEST_a;; t6b) P=+TEST_b;; *) P=+TEST_c;; esac
  LOG="$ROOT/results/swdesc_$t.log"
  ( cd "$W" && iverilog -g2012 -D__ICARUS__ $DEFS -I "$SRC" -I "$TBD" -I "$ROOT/verification" \
      -s swdesc_tb -o sim.vvp $PKGS $REST "$TBD/swdesc_tb.sv" && vvp sim.vvp $P ) > "$LOG" 2>&1
  R=$(grep -E "T6 RESULT|error:" "$LOG" | head -1)
  printf "%-6s %s\n" "$t" "${R:-NO RESULT (see $LOG)}" | tee -a "$SUM"
done
