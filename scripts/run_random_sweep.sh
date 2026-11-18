#!/bin/sh
# Random-matrix regression: for each seed, generate random 2:4-sparse A / dense B (+metadata codes),
# write the sparse and dense memory images and the golden arrays, simulate the FULL CPU+accelerator
# testbench against them, and check PASS.
#   sh scripts/run_random_sweep.sh [N_SEEDS=50] [FIRST_SEED=1]
# Env overrides:  TB=riscv_pipeline_tb  MODE=small|int16|zeros|edge16|int32  CODES=0,1,2,3,4,5  SRC=<rtl dir>
# Per-seed logs: results/sweep/seed_<n>.log     Summary: results/sweep/summary.log
# Reproduce one seed:  python3 scripts/gen_random_data.py --seed <n> --out <dir> --gold <dir>/gold_arrays.svh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=${1:-50}; S0=${2:-1}; TBM=${TB:-riscv_pipeline_tb}
SRC="${SRC:-$ROOT/src}"; TBD="$ROOT/verification/tb"; MEM="$ROOT/mem files"; GEN="$ROOT/scripts/gen_random_data.py"
TBF=$(grep -l "^\s*module\s\+$TBM\b" "$TBD"/*.sv "$TBD"/*.v 2>/dev/null | head -1)
[ -n "$TBF" ] || { echo "module $TBM not found in $TBD"; exit 1; }
OUT="$ROOT/results/sweep"; rm -rf "$OUT"; mkdir -p "$OUT"
PKGS=$(find "$SRC" -name '*_pkg.sv' | sort)
REST=$(find "$SRC" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
GENARGS=""; [ -n "$MODE" ] && GENARGS="$GENARGS --mode $MODE"; [ -n "$CODES" ] && GENARGS="$GENARGS --codes $CODES"
: > "$OUT/gens.txt"; : > "$OUT/cycles.txt"; pass=0; fail=0; failed=""
S=$S0; END=$((S0 + N - 1))
while [ "$S" -le "$END" ]; do
  W="$ROOT/build/sweep/seed_$S"; rm -rf "$W"; mkdir -p "$W/mem files"
  cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null || true
  GENLINE=$(python3 "$GEN" --seed "$S" $GENARGS --out "$W/mem files" --gold "$W/gold_arrays.svh" | grep '^GEN') || { echo "seed $S: generator self-check FAILED"; fail=$((fail+1)); failed="$failed $S"; S=$((S+1)); continue; }
  echo "$GENLINE" >> "$OUT/gens.txt"
  cp "$W/mem files"/*.mem "$W"/                      # bare-name loads see the same data
  LOG="$OUT/seed_$S.log"
  ( cd "$W" && iverilog -g2012 -D__ICARUS__ $DEFS -I "$W" -I "$SRC" -I "$TBD" -I "$ROOT/verification" \
      -s "$TBM" -o sim.vvp $PKGS $REST "$TBF" && vvp sim.vvp ) > "$LOG" 2>&1 || true
  WANT=$(echo "$GENLINE" | sed 's/.*GOLD0=\(-\{0,1\}[0-9]*\).*/\1/')
  GOT=$(grep "H1/H3 x10" "$LOG" | sed -n 's/.*= *\(-\{0,1\}[0-9]\{1,\}\)[^0-9]*$/\1/p' | head -1)
  CYC=$(grep -o "total cycles: *[0-9]*" "$LOG" | grep -o "[0-9]*$" | head -1)
  [ -n "$CYC" ] && echo "$CYC" >> "$OUT/cycles.txt"
  if grep -q "TOP-TO-BOTTOM RUN : PASS" "$LOG" && [ "$GOT" = "$WANT" ]; then
    pass=$((pass+1)); printf "."
  else
    fail=$((fail+1)); failed="$failed $S"; printf "F"
    if [ "$GOT" != "$WANT" ]; then echo; echo "  seed $S: x10 in log is '$GOT', generator golden C[0] is '$WANT' (stale gold or sim error) -> see $LOG"; fi
  fi
  S=$((S+1))
done
echo
python3 - "$OUT/gens.txt" <<'PY' > "$OUT/summary.log.tmp"
import re, sys
tot = [0] * 6; n = 0
for l in open(sys.argv[1]):
    m = re.search(r"META_HIST=\[([^\]]*)\]", l)
    if m:
        n += 1
        for i, v in enumerate(int(x) for x in m.group(1).split(",")): tot[i] += v
print(f"metadata groups exercised over {n} seeds, by code 0..5: {tot}")
PY
{
  echo "random sweep: $pass passed, $fail failed  (TB=$TBM, seeds $S0..$END)"
  [ -n "$failed" ] && echo "failing seeds:$failed"
  echo "distinct total-cycle values: $(sort -u "$OUT/cycles.txt" | tr '\n' ' ')"
  cat "$OUT/summary.log.tmp"; rm -f "$OUT/summary.log.tmp"
} | tee "$OUT/summary.log"