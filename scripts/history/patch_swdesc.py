#!/usr/bin/env python3
"""CPU-authored descriptors: SW to 0x0000_2000..0x0000_2FFF writes descriptor memory.
   addr[11:5] = descriptor index (7b), addr[4:2] = word offset (3b), data = SW rs2.
Hazard guard: a SW is held in ID while a FMAC_START is in EX or the accelerator is
fetching its descriptor (else a SW right behind START could tear the descriptor read).
  -DNO_DESC_STORE_GUARD removes the guard (negative control).
Usage: python3 scripts/patch_swdesc.py            (edits src/riscv_pipeline.v, src/accelerator_top.sv in place)
Idempotent: refuses to patch twice. Originals saved as *.pre_swdesc."""
import re, shutil, sys, os
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
def find(name):
    for d, _, fs in os.walk(os.path.join(root, "src")):
        if name in fs: return os.path.join(d, name)
    sys.exit(f"{name} not found under src/")
def sub1(s, old, new, what):
    if s.count(old) != 1: sys.exit(f"anchor for '{what}' matched {s.count(old)}x -- not patching")
    return s.replace(old, new)

p = find("riscv_pipeline.v"); s = open(p).read()
if "desc_sel" in s: sys.exit("riscv_pipeline.v already patched")
shutil.copy(p, p + ".pre_swdesc")
s = sub1(s, "    wire accelerator_any_error; // sticky error flag",
 "    wire accel_fetching;   // accelerator_top is fetching a descriptor (store-vs-fetch guard)\n    wire accelerator_any_error; // sticky error flag", "decl")
s = sub1(s, "    (id_is_fmac && (accel_busy_reg || idex_is_fmac));",
"""    (id_is_fmac && (accel_busy_reg || idex_is_fmac))
`ifndef NO_DESC_STORE_GUARD
    // a store behind START must not land while the DFU is still reading the descriptor
    || (id_mem_write && (idex_is_fmac || accel_fetching))
`endif
    ;""", "hazard")
s = sub1(s, "    data_memory dmem (",
"""    // CPU-authored descriptors: SW to 0x2000..0x2FFF -> descriptor memory
    wire desc_sel = exmem_mem_write && (exmem_alu[31:12] == 20'h00002);

    data_memory dmem (""", "desc_sel")
s = sub1(s, ".mem_write(exmem_mem_write & ~mmul_sel),", ".mem_write(exmem_mem_write & ~mmul_sel & ~desc_sel),", "dmem we")
s = sub1(s, """        .cpu_we          (desc_we),
        .cpu_desc_idx    (desc_idx),
        .cpu_word_offset (desc_word_off),
        .cpu_wdata       (desc_wdata),""",
"""        .cpu_we          (desc_we | desc_sel),
        .cpu_desc_idx    (desc_sel ? exmem_alu[11:5] : desc_idx),
        .cpu_word_offset (desc_sel ? exmem_alu[4:2]  : desc_word_off),
        .cpu_wdata       (desc_sel ? exmem_rs2       : desc_wdata),
        .desc_fetch_busy (accel_fetching),""", "port mux")
open(p, "w").write(s)

p = find("accelerator_top.sv"); s = open(p).read()
if "desc_fetch_busy" in s: sys.exit("accelerator_top.sv already patched")
shutil.copy(p, p + ".pre_swdesc")
s = sub1(s, "    output job_status_t                 debug_job_status\n);",
"    output job_status_t                 debug_job_status,\n    output logic                        desc_fetch_busy\n);", "port")
s = sub1(s, "    assign all_done  = (top_state == TOP_DONE);",
"    assign all_done  = (top_state == TOP_DONE);\n    assign desc_fetch_busy = (top_state == TOP_FETCH) || (top_state == TOP_WAIT_FETCH);", "assign")
open(p, "w").write(s)
print("patched riscv_pipeline.v + accelerator_top.sv")
