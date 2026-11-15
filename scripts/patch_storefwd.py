#!/usr/bin/env python3
"""Store-data forwarding fix: ex_mem got idex_rs2 (unforwarded) as store data, so a SW whose rs2 was
produced by one of the 2 preceding instructions stored a STALE register value. Now uses forwarded_rs2.
-DNO_STORE_FWD_FIX restores the original behaviour (negative control).  Idempotent; saves *.pre_storefwd."""
import os, shutil, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
for d, _, fs in os.walk(os.path.join(root, "src")):
    if "riscv_pipeline.v" in fs: p = os.path.join(d, "riscv_pipeline.v")
s = open(p).read()
if "NO_STORE_FWD_FIX" in s: sys.exit("already patched")
old = "        .rs2_data_in(idex_rs2),"
if s.count(old) != 1: sys.exit(f"anchor matched {s.count(old)}x -- not patching")
shutil.copy(p, p + ".pre_storefwd")
open(p, "w").write(s.replace(old, "`ifdef NO_STORE_FWD_FIX\n        .rs2_data_in(idex_rs2),\n`else\n        .rs2_data_in(forwarded_rs2),\n`endif"))
print("patched", p)
