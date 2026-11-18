#!/usr/bin/env python3
"""Make the CPU's debug prints opt-in, and stop them hiding real logic from synthesis.

Two problems, one fix:
  1. if_id.v and mem_wb.v wrapped their WHOLE always block in `ifndef SYNTHESIS
     (so the IF/ID and MEM/WB pipeline registers did not exist in synthesis --
     same bug class as the old register-file guard).
  2. Per-cycle $display calls in the CPU slow every CPU-level simulation down a lot.

After this patch:
  - if_id / mem_wb registers are always present; only their $display lines are guarded.
  - Every CPU debug print is under `ifdef NC_TRACE (off by default, off in synthesis).
    Turn traces back on with:  DEFS="-DNC_TRACE" sh scripts/run_tb.sh ...
Simulation behaviour is otherwise unchanged (only $display statements move).
Idempotent; backs up each file it changes as <file>.pre_quiet.

usage: python3 scripts/patch_quiet_trace.py [src_dir]   (default: src)
"""
import os, re, shutil, sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "src"
MARK = "// [quiet_trace]"
DISPLAY = re.compile(r"^([ \t]*)\$display\(.*?\);[ \t]*$", re.S | re.M)


def wrap_displays(text):
    """Put `ifdef NC_TRACE around every $display(...); statement (may span lines)."""
    def rep(m):
        ind = m.group(1)
        return f"`ifdef NC_TRACE\n{m.group(0)}\n`endif"
    return DISPLAY.sub(rep, text)


def unguard_block(text):
    """Remove the outer `ifndef SYNTHESIS ... `endif that hid the always block."""
    new, n = re.subn(r"^[ \t]*`ifndef SYNTHESIS[ \t]*\n(.*?)^[ \t]*`endif[ \t]*\n",
                     r"\1", text, count=1, flags=re.S | re.M)
    assert n == 1, "expected exactly one `ifndef SYNTHESIS block"
    return new


def swap_guard(text):
    """All `ifndef SYNTHESIS blocks in these files are display-only: make them opt-in."""
    return re.sub(r"`ifndef SYNTHESIS", "`ifdef NC_TRACE", text)


PLAN = {
    "if_id.v":                  lambda t: wrap_displays(unguard_block(t)),
    "mem_wb.v":                 lambda t: wrap_displays(unguard_block(t)),
    "riscv_pipeline.v":         swap_guard,
    "hazard_detection_unit.sv": swap_guard,
    "register_file.v":          swap_guard,
}

for name, fn in PLAN.items():
    p = os.path.join(SRC, name)
    t = open(p).read()
    if MARK in t:
        print(f"{name}: already patched"); continue
    n = fn(t)
    assert "`ifndef SYNTHESIS" not in n, f"{name}: a SYNTHESIS guard survived"
    shutil.copy(p, p + ".pre_quiet")
    open(p, "w").write(f"{MARK} debug prints are opt-in: compile with -DNC_TRACE\n" + n)
    print(f"{name}: patched")
