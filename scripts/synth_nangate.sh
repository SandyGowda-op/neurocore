#!/bin/sh
# usage: sh scripts/synth_nangate.sh [top] [clock_period_ns]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOP=${1:-accelerator_top}; PERIOD=${2:-10}
LIB=${LIB:-$HOME/eda_libs/NangateOpenCellLibrary_typical.lib}
OUT="$ROOT/results/synth/$TOP"; mkdir -p "$OUT"

# black-box stub for the behavioral DMA memory model
cat > "$OUT/bb.sv" <<'EOF'
(* blackbox *)
module main_memory_model #(
  parameter integer DATA_WIDTH = 64, parameter integer MEMORY_SIZE = 65536,
  parameter integer MEMORY_LATENCY = 3, parameter string MEMORY_INIT_FILE = "",
  parameter bit VERBOSE = 1'b0, parameter logic [31:0] MEM_BASE = 32'h1000_0000
)( input logic clk, input logic rst,
   input logic mem_req_valid, output logic mem_req_ready,
   input logic [31:0] mem_req_addr, input logic [31:0] mem_req_bytes,
   input logic mem_req_write,
   output logic mem_rvalid, output logic [63:0] mem_rdata, output logic mem_rlast );
endmodule
EOF

PKGS=$(find "$ROOT/src" -name '*_pkg.sv' | sort)
REST=$(find "$ROOT/src" \( -name '*.sv' -o -name '*.v' \) ! -name '*_pkg.sv' \
        ! -name 'main_memory_model.sv' | sort)

cat > "$OUT/synth.ys" <<EOF
plugin -i slang
read_slang --top $TOP -D SYNTHESIS --keep-hierarchy $(echo $PKGS $REST) $OUT/bb.sv
hierarchy -check -top $TOP
synth -top $TOP
delete t:\$print
dfflibmap -liberty $LIB
abc -liberty $LIB -D $(( PERIOD * 1000 ))
opt_clean -purge
stat -liberty $LIB -top $TOP
write_verilog -noattr $OUT/netlist.v
EOF
yosys -q -l "$OUT/yosys.log" -s "$OUT/synth.ys"
echo "==== AREA ($TOP, um^2, Nangate45 typical) ===="
grep -E "Chip area|=== " "$OUT/yosys.log"

if command -v sta >/dev/null 2>&1; then
cat > "$OUT/sta.tcl" <<EOF
read_liberty $LIB
read_verilog $OUT/netlist.v
link_design $TOP
create_clock -name clk -period $PERIOD [get_ports clk]
report_checks -path_delay max -digits 3
report_worst_slack -max -digits 3
exit
EOF
sta -no_splash "$OUT/sta.tcl" | tee "$OUT/sta.log" | tail -40
echo "Fmax = 1000 / ($PERIOD - worst_slack) MHz"
else
echo "sta not found on PATH -- area only"
fi