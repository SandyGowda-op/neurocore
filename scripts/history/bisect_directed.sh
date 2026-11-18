#!/bin/sh
# Which change broke T2/T3?   sh scripts/bisect_directed.sh
# Runs T2 and T3 under: current src, each negative-control macro, all macros, and git HEAD's src (baseline).
# Prints one line per config: number of FAIL lines in T2 / T3.  Compiler noise is suppressed.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TB="$ROOT/verification/tb"; MEM="$ROOT/mem files"; PROGS="$MEM/directed"
run_cfg() {   # name src defs
  name=$1; src=$2; defs=$3; out=""
  for t in 2 3; do
    W="$ROOT/build/bisect/$name/t$t"; rm -rf "$W"; mkdir -p "$W/mem files"
    cp "$MEM"/*.mem "$W/mem files"/ 2>/dev/null; cp "$MEM"/*.mem "$W"/ 2>/dev/null
    cp "$PROGS/t$t.mem" "$W/mem files/instruction_memory.mem"; cp "$PROGS/t$t.mem" "$W/instruction_memory.mem"
    PKGS=$(find "$src" -name '*_pkg.sv' | sort)
    REST=$(find "$src" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' | sort)
    if ( cd "$W" && iverilog -g2012 -D__ICARUS__ $defs -I "$src" -I "$TB" -I "$ROOT/verification" \
          -s hazard_directed_tb -o sim.vvp $PKGS $REST "$TB/hazard_directed_tb.sv" ) >/dev/null 2>&1; then
      n=$(cd "$W" && vvp sim.vvp +TEST=$t 2>&1 | grep -cE "^ +FAIL")
    else n="compile-error"; fi
    out="$out  T$t:FAILs=$n"
  done
  printf "%-34s%s\n" "$name" "$out"
}
S="$ROOT/src"
run_cfg "current"                      "$S" ""
run_cfg "no store-guard"               "$S" "-DNO_DESC_STORE_GUARD"
run_cfg "no store-fwd fix"             "$S" "-DNO_STORE_FWD_FIX"
run_cfg "no rf bypass"                 "$S" "-DNO_RF_BYPASS"
run_cfg "no guard+fwd+bypass"          "$S" "-DNO_DESC_STORE_GUARD -DNO_STORE_FWD_FIX -DNO_RF_BYPASS"
B="$ROOT/build/bisect/base"; rm -rf "$B"; mkdir -p "$B"
if (cd "$ROOT" && git archive HEAD src | tar -x -C "$B") 2>/dev/null; then
  run_cfg "git HEAD src (baseline)"    "$B/src" ""
else echo "git HEAD baseline: unavailable"; fi