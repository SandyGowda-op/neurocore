#!/bin/sh
# T7 distance-3 RAW.  sh scripts/run_rawd3.sh      Negative control: DEFS="-DNO_RF_BYPASS" sh scripts/run_rawd3.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$ROOT/src}"; TBD="$ROOT/verification/tb"; MEM="$ROOT/mem files"
W="$ROOT/build/rawd3"; rm -rf "$W"; mkdir -p "$W/mem files" "$ROOT/results"
cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null; cp "$MEM"/*.mem "$W"/ 2>/dev/null
python3 "$ROOT/scripts/gen_t7_prog.py" "$W/mem files/instruction_memory.mem" || exit 1
cp "$W/mem files/instruction_memory.mem" "$W/instruction_memory.mem"
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
LOG="$ROOT/results/rawd3.log"
( cd "$W" && iverilog -g2012 -D__ICARUS__ $DEFS -I "$SRC" -I "$TBD" -I "$ROOT/verification" \
    -s rawd3_tb -o sim.vvp $PKGS $REST "$TBD/rawd3_tb.sv" && vvp sim.vvp ) > "$LOG" 2>&1
grep -E "OK|FAIL|T7 RESULT|error:" "$LOG"