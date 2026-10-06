#!/usr/bin/env python3
"""Adds the high-word read to FMAC_READ in src/riscv_pipeline.v:
   rs1[6]=1 -> status {busy,error};  rs1[7]=1 -> result bits [63:32];  else result bits [31:0].
Usage: python3 patch_highword.py src/riscv_pipeline.v   (edits in place; refuses if the pattern isn't found once)"""
import sys
p = sys.argv[1]; s = open(p).read()
old = ": accel_read_data[31:0]) :"
new = ": (forwarded_rs1[7] ? accel_read_data[63:32] : accel_read_data[31:0])) :"
assert s.count(old) == 1, "pattern not found exactly once -- check the status-read patch is applied"
open(p, "w").write(s.replace(old, new)); print("patched", p)