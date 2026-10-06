#!/bin/sh
# 64-bit result check: takes a seed whose result overflows int32 (default seed 1 -> C[43]),
# reads that element back as {FMAC_READ high word, low word} on BOTH sparse and dense paths.
#   sh scripts/run_hiword_check.sh [SEED=1]      (run once BEFORE the RTL patch -> expect FAIL, once AFTER -> PASS)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SEED=${1:-1}; SRC="${SRC:-$ROOT/src}"; TBD="$ROOT/verification/tb"; MEM="$ROOT/mem files"
W="$ROOT/build/hiword"; rm -rf "$W"; mkdir -p "$W/mem files" "$W/progs"
cp "$MEM"/*.mem "$W/mem files"/
INFO=$(python3 "$ROOT/scripts/gen_random_data.py" --seed "$SEED" --allow-overflow --out "$W/mem files" --gold "$W/gold_arrays.svh" | grep '^GEN')
IDX=$(echo "$INFO" | sed -n 's/.*OVERFLOW_IDX=\[\([0-9]*\).*/\1/p')
[ -n "$IDX" ] || { echo "seed $SEED has no int32-overflow element; try seed 1 or 47"; exit 1; }
HI_IDX=$IDX python3 "$ROOT/scripts/gen_progs.py" "$W/progs" > /dev/null
cp "$W/progs/t5.mem" "$W/mem files/instruction_memory.mem"; cp "$W/mem files"/*.mem "$W"/
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort); REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
( cd "$W" && iverilog -g2012 -D__ICARUS__ -I "$W" -I "$SRC" -I "$TBD" -I "$ROOT/verification" -s hazard_directed_tb \
    -o sim.vvp $PKGS $REST "$TBD/hazard_directed_tb.sv" && vvp sim.vvp +TEST=5 +IDX=$IDX ) > "$ROOT/results/hiword.log" 2>&1 || true
echo "seed $SEED, element C[$IDX]:"; grep -E "PASS|FAIL|====|error" "$ROOT/results/hiword.log"