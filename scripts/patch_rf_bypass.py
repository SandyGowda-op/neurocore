#!/usr/bin/env python3
"""register_file.v:
 1) write-through bypass: a read in the same cycle as a write-back to the same register sees the new value
    (fixes the distance-3 RAW hazard; -DNO_RF_BYPASS restores the original, for the negative control)
 2) synthesis fix: the register-write always block was inside `ifndef SYNTHESIS (no register file in synthesis!).
    Only the $display is simulation-only now. Simulation behaviour is unchanged.
Idempotent; saves register_file.v.pre_rfbypass."""
import os, shutil, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
p = None
for d, _, fs in os.walk(os.path.join(root, "src")):
    if "register_file.v" in fs: p = os.path.join(d, "register_file.v")
if not p: sys.exit("register_file.v not found")
s = open(p).read()
if "NO_RF_BYPASS" in s: sys.exit("already patched")
L = s.split("\n"); shutil.copy(p, p + ".pre_rfbypass")
# (2) synthesis scoping
i_if = next(i for i, l in enumerate(L) if l.strip() == "`ifndef SYNTHESIS")
i_en = next(i for i, l in enumerate(L) if l.strip() == "`endif" and i > i_if)
i_dp = next(i for i, l in enumerate(L) if "$display(\"REGFILE WRITE" in l)
L[i_dp] = "`ifndef SYNTHESIS\n" + L[i_dp] + "\n`endif"
del L[i_en]; del L[i_if]
s = "\n".join(L)
# (1) bypass
old1 = "    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];"
old2 = "    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];"
assert s.count(old1) == 1 and s.count(old2) == 1, "assign anchors not found"
new = """`ifdef NO_RF_BYPASS
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];
`else
    // write-through: same-cycle write-back is visible to the ID-stage read
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 :
                      (we_en && we_addr == rs1_addr) ? we_data : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 :
                      (we_en && we_addr == rs2_addr) ? we_data : regs[rs2_addr];
`endif"""
s = s.replace(old1 + "\n" + old2, new)
assert "NO_RF_BYPASS" in s, "assign pair not contiguous"
open(p, "w").write(s); print("patched", p)