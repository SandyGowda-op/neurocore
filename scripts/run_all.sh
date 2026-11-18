#!/bin/sh
# Full NeuroCore regression with negative controls. Prints one line per check.
#   sh scripts/run_all.sh [SWEEP_SEEDS=50]
# A negative control re-runs a test with one fix compiled out (-DNO_...);
# it is EXPECTED to fail -- that proves the test can see the bug.
# Full logs: results/  (per-test logs) and results/run_all.txt (this summary)
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT" || exit 1
SEEDS=${1:-50}
mkdir -p results; OUT=results/run_all.txt; : > "$OUT"
ok=0; bad=0
say() { printf '%-58s %s\n' "$1" "$2" | tee -a "$OUT"; }
check() {   # check <label> <expect PASS|FAIL> <got PASS|FAIL> [note]
  if [ "$2" = "$3" ]; then ok=$((ok+1)); say "$1" "ok ($3${4:+, $4})"
  else bad=$((bad+1)); say "$1" "MISMATCH: expected $2, got $3${4:+ ($4)}"; fi
}
t0=$(date +%s)

# 0. accelerator unit + integration testbenches (out-of-date ones are in verification/stale/)
unit() {   # unit <tb_module> <regex only a passing run prints>
  sh scripts/run_tb.sh "$1" >/dev/null 2>&1
  if grep -qE "$2" "results/$1.log" && ! grep -qE "\[FAIL\]|^FAIL|TIMEOUT|error:" "results/$1.log"
  then r=PASS; else r=FAIL; fi
  check "unit: $1" PASS "$r"
}
unit mac_unit_tb                          "OVERALL RESULT : PASS"
unit metadata_decoder_tb                  "Metadata Decoder Test PASSED"
unit scratchpad_tb                        "All Executed Tests PASSED"
unit scratchpad_controller_tb             "SCRATCHPAD CONTROLLER TEST PASSED"
unit scratchpad_sparse_tb                 "SCRATCHPAD SPARSE TEST COMPLETE"
unit scratchpad_controller_integration_tb "OVERALL RESULT : PASS"
unit tile_walker_tb                       "OVERALL RESULT : PASS"
unit compute_controller_tb                "OVERALL RESULT : PASS"
unit compute_controller_pipelined_tb      "COMPUTE CONTROLLER \(50 seeds.*PASS"
unit sparse_compute_controller_tb         "SPARSE COMPUTE CONTROLLER TEST PASSED"
unit sparse_datapath_wrapper_tb           "SPARSE DATAPATH WRAPPER TEST COMPLETE"

# 1. directed hazard tests T1-T4
n=$(sh scripts/run_directed.sh 2>&1 | grep -c "TEST [0-9] : PASS")
check "T1-T4 directed hazard tests ($n/4 pass)" PASS "$([ "$n" = 4 ] && echo PASS || echo FAIL)"

# 1b. T5: 64-bit result read back as two 32-bit halves (int32-overflowing element)
r=$(sh scripts/run_hiword_check.sh 2>&1 | grep -q "TEST 5 : PASS" && echo PASS || echo FAIL)
check "T5 64-bit result high/low word read" PASS "$r"

# 2. T7 distance-3 RAW, and its negative control
r=$(sh scripts/run_rawd3.sh 2>&1 | grep -o "T7 RESULT: [A-Z]*" | awk '{print $3}')
check "T7 distance-3 RAW" PASS "${r:-FAIL}"
r=$(DEFS="-DNO_RF_BYPASS" sh scripts/run_rawd3.sh 2>&1 | grep -o "T7 RESULT: [A-Z]*" | awk '{print $3}')
check "  neg. control: no register-file bypass" FAIL "${r:-PASS}"

# 3. T6 CPU-authored descriptors, and two negative controls
s=$(TAGSUFFIX=_ok sh scripts/run_swdesc.sh 2>&1)
n=$(echo "$s" | grep -c "T6 RESULT: PASS")
check "T6 CPU-authored descriptors ($n/7 pass)" PASS "$([ "$n" = 7 ] && echo PASS || echo FAIL)"
s=$(TAGSUFFIX=_nofwd DEFS="-DNO_STORE_FWD_FIX" sh scripts/run_swdesc.sh 2>&1)
r=$(echo "$s" | grep "^t6b" | grep -q "T6 RESULT: PASS" && echo PASS || echo FAIL)
check "  neg. control: no store-data forwarding (t6b)" FAIL "$r"
s=$(TAGSUFFIX=_noguard DEFS="-DNO_DESC_STORE_GUARD" sh scripts/run_swdesc.sh 2>&1)
n=$(echo "$s" | grep -E "^t6c[1245]" | grep -c "FAIL")
check "  neg. control: no store guard (t6c1/2/4/5)" FAIL "$([ "$n" = 4 ] && echo FAIL || echo PASS)" "$n/4 fail"

# 4. multi-job descriptor addressing
for args in "32 1" "64 7 +IDENT"; do
  s=$(sh scripts/run_multijob.sh $args 2>&1)
  r=$(echo "$s" | grep -q "MULTIJOB: PASS" && echo "$s" | grep -q "MEM_OOB beats: 0" && echo PASS || echo FAIL)
  check "multijob ($args)" PASS "$r"
done

# 5. full CPU + accelerator system test, and accelerator-level equivalence test
sh scripts/run_tb.sh riscv_pipeline_tb >/dev/null 2>&1
cyc=$(grep -o "total cycles: *[0-9]*" results/riscv_pipeline_tb.log | grep -o "[0-9]*$")
r=$(grep -q "TOP-TO-BOTTOM RUN : PASS" results/riscv_pipeline_tb.log && echo PASS || echo FAIL)
check "riscv_pipeline_tb (H1-H9)" PASS "$r" "total cycles ${cyc:-?}"
sh scripts/run_tb.sh accelerator_top_tb >/dev/null 2>&1
r=$(grep -q "RESEARCH RUN : PASS" results/accelerator_top_tb.log && echo PASS || echo FAIL)
check "accelerator_top_tb (sparse, dense, equivalence)" PASS "$r"

# 6. random-matrix sweep through the full system
if [ "$SEEDS" -gt 0 ]; then
  sh scripts/run_random_sweep.sh "$SEEDS" >/dev/null 2>&1
  line=$(head -1 results/sweep/summary.log 2>/dev/null)
  r=$(echo "$line" | grep -q " 0 failed" && echo PASS || echo FAIL)
  check "random sweep ($SEEDS seeds)" PASS "$r" "$line"
fi

say "----" ""
say "checks as expected: $ok   mismatches: $bad   ($(( $(date +%s) - t0 ))s)" ""
[ "$bad" = 0 ]
