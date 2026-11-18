#!/usr/bin/env python3
"""Merge transfer_engine's second always_ff (phase/address/byte-count updates)
into the main FSM always_ff, so current_address, bytes_remaining,
current_spad_write_addr and transfer_phase each have ONE driver.
Behaviour-preserving: the moved block fires only when burst_fully_consumed
(=> fifo_empty => no fifo_read) and state==WAIT_DATA (=> no request accept),
so it never overlaps the other assignments in the same cycle.
Idempotent; backs up the original as transfer_engine.sv.pre_temerge."""
import sys, shutil, os
path = sys.argv[1] if len(sys.argv) > 1 else "src/transfer_engine.sv"
src = open(path).read()
MARK = "// [te_merge] phase/address updates merged into main FSM block"
if MARK in src:
    print("already patched"); sys.exit(0)

hdr = "    //==========================================================================\n    // Phase / Address / Byte Count Updates"
out_hdr = "    //==========================================================================\n    // Output Logic"
a = src.index(hdr); b = src.index(out_hdr)
second = src[a:b]

# body = the 'if (state == WAIT_DATA && burst_fully_consumed) begin ... end' inside 'if (!rst) begin'
s = second.index("            if (state == WAIT_DATA &&")
e = second.rindex("        end\n\n    end")          # closes 'if (!rst)', then always_ff
body = second[s:e].rstrip() + "\n"

anchor = ("            if (fifo_read) begin\n\n"
          "                current_spad_write_addr <=\n"
          "                    current_spad_write_addr +\n"
          "                    BYTES_PER_BEAT;\n\n"
          "            end\n")
assert src.count(anchor) == 1, "anchor not found exactly once"
new = src.replace(anchor, anchor + "\n            " + MARK + "\n" + body, 1)
new = new.replace(second, "", 1)
# The moved block uses burst_fully_consumed, which was declared further down.
# Icarus 12 accepts use-before-declaration; Icarus 14 does not. Move the helper up.
hi = new.index("    //==========================================================================\n    // Phase Transition Helper\n")
hj = new.index("        fifo_empty;\n", hi) + len("        fifo_empty;\n")
helper = new[hi:hj]
new = new[:hi] + new[hj:]
fsm = "    //==========================================================================\n    // FSM Sequential Logic\n"
new = new.replace(fsm, helper + "\n" + fsm, 1)
shutil.copy(path, path + ".pre_temerge")
open(path, "w").write(new)
print("patched", path)
