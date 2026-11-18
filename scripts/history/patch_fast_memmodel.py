#!/usr/bin/env python3
"""Speed up Icarus compiles: give main_memory_model's read combiner an explicit
sensitivity list instead of always_comb.

Why: always_comb made Icarus treat the process as sensitive to every byte of the
64 KB `memory` array. Elaborating that took ~2.5 minutes per compile
(transfer_engine_memory_tb: 144 s -> 0.04 s with this change).

Why it is behaviour-preserving: the combiner only produces data while
state == STREAM_DATA, and nothing writes `memory` during a stream (the model
has no write port; testbenches load/poke it only while idle). Every beat
changes beat_counter, and entering STREAM_DATA changes state, so the block
re-evaluates exactly when its output can change.

main_memory_model is a simulation model (black-boxed in synthesis), so no
hardware changes. Idempotent; backs up the original as .pre_fastmem.
usage: python3 scripts/history/patch_fast_memmodel.py [src/main_memory_model.sv]
"""
import shutil, sys
p = sys.argv[1] if len(sys.argv) > 1 else "src/main_memory_model.sv"
s = open(p).read()
NEW = "always @(state or current_address or beat_counter) begin  // [fast_memmodel]"
if "[fast_memmodel]" in s:
    print("already patched"); sys.exit(0)
OLD = "integer i;\n\nalways_comb begin\n\n    read_data    = '0;"
assert s.count(OLD) == 1, "read-combiner block not found exactly once"
shutil.copy(p, p + ".pre_fastmem")
open(p, "w").write(s.replace(OLD, "integer i;\n\n" + NEW + "\n\n    read_data    = '0;", 1))
print("patched", p)
