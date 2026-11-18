# NeuroCore

[![regression](https://github.com/SandyGowda-op/neurocore/actions/workflows/regression.yml/badge.svg)](https://github.com/SandyGowda-op/neurocore/actions/workflows/regression.yml)

**A RISC-V CPU with a descriptor-driven matrix accelerator that runs dense 8×8
and 2:4-sparse workloads, plus a verification study of the hazards that
appear when the CPU and accelerator are tightly coupled.**

Software decides how work is laid out: it writes a small *descriptor* (addresses, sizes, strides,
dense-or-sparse flag) into descriptor memory, then issues one custom
instruction to run it. The hardware fetches the descriptor, moves the data
with its own DMA engine, computes, and the CPU reads results back with another
custom instruction. The accelerator does not check the 2:4 sparsity pattern;
it trusts the descriptor, which keeps the control logic small.

## Contents
- [Architecture](#architecture)
- [The custom instructions](#the-custom-instructions)
- [CPU–accelerator coupling hazards](#cpuaccelerator-coupling-hazards)
- [Verification results](#verification-results)
- [Performance](#performance)
- [Area](#area)
- [Known limits](#known-limits)
- [Run it](#run-it)
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)

## Architecture

```
   RISC-V 5-stage pipeline (RV32I subset + custom-0)
     │  SW 0x2000-0x2FFF ──────────► descriptor memory (128 × 8 words)
     │  FMAC_SETDESC / FMAC_START ─► descriptor fetch unit ─► descriptor controller
     │                                                          │ flags[0]: dense / sparse
     │                                                    scheduler engine
     │                                         ┌────────────────┴────────────────┐
     │                               dense subsystem                    sparse subsystem (2:4)
     │                       tile walker + tile generator            sparse tile generator
     │                       transfer engine (DMA)                   transfer engine (DMA)
     │                       scratchpad A / B                        scratchpad A / B / metadata
     │                       pipelined MAC controller                8×8 sparse compute (metadata-gated)
     │                                         └────────────────┬────────────────┘
     └◄────────── FMAC_READ (element, status, high word) ───────┘
```

- **CPU:** 5-stage in-order pipeline, branches resolved in ID, forwarding into
  EX and into the ID branch compare, load-use stall, register-file write-through.
- **Accelerator:** one 8×8 tile per descriptor. Dense: 512 MACs. Sparse 2:4:
  256 MACs on compressed A plus 3-bit metadata per group of four.

## The custom instructions

custom-0 opcode `0x0B`:

| Instruction | funct3 | Effect |
|---|---|---|
| `FMAC_SETDESC rs1` | 3 | select descriptor `rs1[6:0]` |
| `FMAC_START` | 0 | run the selected descriptor |
| `FMAC_READ rd, rs1` | 2 | `rs1[5:0]` element of the 8×8 result; `rs1[6]` → status `{busy, error}`; `rs1[7]` → high 32 bits |
| `RELU rd, rs1` | 1 | ReLU on a register |

Descriptors can be preloaded over a bus or written by the CPU itself with
ordinary stores to `0x2000–0x2FFF` (`index = addr[11:5]`, `word = addr[4:2]`).

## CPU–accelerator coupling hazards

Each row is a bug that existed, its fix, the test that catches it, and where
there is one, the **negative control**: the same test rebuilt with the fix
compiled out, which must fail.

| # | Hazard | Fix | Test | Negative control |
|---|---|---|---|---|
| 1 | Second `FMAC_START` while a job runs is silently dropped | stall `START` while busy | T1, H7 | – |
| 2 | ALU result → `BEQ` right behind it compares a stale value | 1-cycle stall | T2 | – |
| 3 | `FMAC_READ` result → `BEQ` right behind it | 1-cycle stall | T3 | – |
| 4 | Invalid descriptor (rows/cols/k = 0) hangs the accelerator | error path, status readable | T4 | – |
| 5 | 64-bit result truncated to 32 bits | `rs1[7]` reads the high word | T5 | – |
| 6 | `FMAC_READ` right behind `START` returns the previous job's result | hold read while `START` is in EX | H2 | – |
| 7 | Store data not forwarded (stale value written) | forward into EX/MEM store data | T6b | `-DNO_STORE_FWD_FIX` |
| 8 | Value written 3 instructions earlier read stale from the register file | write-through bypass | T7 | `-DNO_RF_BYPASS` |
| 9 | A store right behind `START` corrupts the descriptor being fetched | stall stores during `START`/fetch | T6c | `-DNO_DESC_STORE_GUARD` |

Bugs found by synthesis rather than simulation, all fixed:

- the register file's write logic and the IF/ID and MEM/WB pipeline registers
  were inside `ifndef SYNTHESIS`, so they did not exist in a synthesised netlist;
- `transfer_engine` drove four registers from two different `always_ff` blocks,
  so synthesis did not match simulation.

## Verification results

`sh scripts/run_all.sh`, clean checkout; passes on Icarus Verilog 12.0 and 14.0 (devel):

```
unit: 11 accelerator unit / integration testbenches        ok (PASS)
T1-T4 directed hazard tests (4/4 pass)                     ok (PASS)
T5 64-bit result high/low word read                        ok (PASS)
T7 distance-3 RAW                                          ok (PASS)
  neg. control: no register-file bypass                    ok (FAIL)
T6 CPU-authored descriptors (7/7 pass)                     ok (PASS)
  neg. control: no store-data forwarding (t6b)             ok (FAIL)
  neg. control: no store guard (t6c1/2/4/5)                ok (FAIL, 4/4 fail)
multijob (32 1)                                            ok (PASS)
multijob (64 7 +IDENT)                                     ok (PASS)
riscv_pipeline_tb (H1-H9)                                  ok (PASS, total cycles 3209)
accelerator_top_tb (sparse, dense, equivalence)            ok (PASS)
random sweep (50 seeds)                                    ok (PASS, 50 passed, 0 failed)
```

What the system-level tests do:

- **riscv_pipeline_tb (H1–H9):** a real program on the CPU runs a sparse and a
  dense job, reads all 128 results back through `FMAC_READ`, and checks
  stalls, stale-read protection, dropped-dispatch protection and equality of
  the sparse and dense results.
- **multijob:** up to 64 descriptors, each pointing at a different memory
  window (mapping reversed so descriptor index ≠ window), all through the
  `FMAC_READ` path.
- **random sweep:** 50 random 2:4-sparse A / dense B matrices through the full
  CPU + accelerator, all six metadata codes exercised, checked against a
  Python golden model.
- **accelerator_top_tb:** the same A×B run through the sparse path (compressed)
  and the dense path (expanded); both must match each other and a golden
  model, including a random case.

"Verified" here means directed tests, negative controls and randomised tests,
not a formal proof. `verification/stale/` holds older unit testbenches that no
longer match the RTL (see `STALE.md`).

## Performance

Cycle counts from `accelerator_top_tb`, one 8×8 tile:

| | Dense | Sparse 2:4 | Ratio |
|---|---|---|---|
| MACs | 512 | 256 | 2.0× |
| Compute phase | 580 cycles | 322 cycles | 1.80× |
| Whole job (fetch → done) | 826 cycles | 610 cycles | 1.35× |
| Bytes moved | 512 B | 448 B (incl. 64 B metadata) | 1.14× |

The gap between the 1.80× compute ratio and the 1.35× whole-job ratio is
fixed overhead: descriptor fetch, scheduling and data movement don't shrink
with sparsity. The full CPU test program takes 3209 cycles. An earlier
loader/compute optimisation pass (tag `opt-v1`) took the dense job from 2487
to 826 cycles and the sparse job from 1255 to 610.

## Area and timing

Yosys + OpenSTA, Nangate45 typical corner, post-synthesis, pre-layout
(no wire load, ideal clock), 10 ns target. The descriptor memory is treated
as an SRAM macro (black box), as a real chip would; synthesising it as
flip-flops adds about 301,000 µm² and creates huge-fanout nets.

| Block | Area (µm²) | Fmax |
|---|---|---|
| Descriptor fetch unit | 5,147 | ≈ 198 MHz |
| Descriptor controller | 2,280 | ≈ 171 MHz |
| Top-level sequencer | ≈ 92 | – |
| **Dispatch control total** | **≈ 7,519** | **≥ 171 MHz** |
| Whole accelerator (descriptor memory as SRAM) | 283,408 | not yet measured |

Dispatch control is about **2.7% of the accelerator's logic area**.
A whole-accelerator Fmax is not reported yet: its worst paths are dominated
by unbuffered high-fanout nets (one register driving ~1,000 inputs), which
Yosys does not fix. That needs buffer insertion and gate sizing
(OpenROAD `repair_design`); it is next on the list.

Reproduce: `sh scripts/synth_nangate.sh accelerator_top 10`,
`sh scripts/synth_nangate.sh descriptor_fetch_unit 10`,
`sh scripts/synth_nangate.sh descriptor_controller 10`
(`SRAM_BB=0` synthesises the descriptor memory as flip-flops).

## Known limits

- One 8×8 tile per descriptor; no accumulation across K tiles, and results are
  not written back to `dst_addr` (the CPU reads them with `FMAC_READ`).
- Each subsystem has a private, read-only behavioural memory model (not
  synthesisable; black-boxed in synthesis).
- CPU instruction subset: `ADD`, `ADDI`, `LUI`, `LW`, `SW`, `BEQ` + custom ops.
  No multiply, `SUB`, `SLT` or shifts.
- In Icarus the sparse result is read through a hierarchical reference (an
  Icarus port limitation); other tools use the port path.
- The dense MAC counter is cumulative across jobs (it does not reset per job).
- No formal verification yet. Early SVA files for the fetch unit are kept in
  `legacy/assertions/` but are not part of the regression.
- No whole-accelerator Fmax yet (needs buffer insertion / OpenROAD); control-block timing is reported above.

## Run it

Needs Icarus Verilog ≥ 12 and Python 3. Synthesis also needs Yosys with the
slang plugin (OSS CAD Suite), OpenSTA, and a Nangate45 `.lib`.

```sh
sh scripts/run_all.sh                     # everything, about 20 s
sh scripts/run_all.sh 200                 # same, with a 200-seed random sweep
sh scripts/run_tb.sh riscv_pipeline_tb    # one testbench
DEFS="-DNC_TRACE" sh scripts/run_tb.sh riscv_pipeline_tb   # with per-cycle CPU trace
sh scripts/synth_nangate.sh accelerator_top 10             # area + timing
```

## Repository layout

```
src/                  RTL (CPU + accelerator); riscv_pipeline.v is the system top
verification/tb/      testbenches in the regression
verification/stale/   older unit testbenches that no longer match the RTL
scripts/              run_all.sh, runners, program/data generators, synthesis
scripts/history/      patch scripts that introduced past fixes (already applied)
mem files/            program and data images
docs/                 design notes, ISA docs, decision records (see docs/README.md)
legacy/               retired RTL, old flow scripts, early SVA files
```

## Roadmap

1. Make the accelerator usable as a small NPU: write results to `dst_addr`,
   K-tile accumulation (`FLAG_ACCUMULATE`), fused ReLU (`FLAG_RELU_ENABLE`),
   a data window shared by CPU and accelerator, and `SUB`/`SLT`/`BLT`/shifts
   on the CPU.
2. A small compiler that takes a trained network, chooses dense or 2:4 per
   tile, and emits descriptors and the RISC-V program; then digit recognition
   (8×8 images) running on NeuroCore, reporting accuracy against cycles.
3. Optional: descriptor chaining (one `START` per layer), the systolic array
   from [tpu_research](https://github.com/SandyGowda-op/tpu_research) as the
   dense engine, and an FPGA demo.

## Related repositories

- [riscv-ai-accelerator](https://github.com/SandyGowda-op/riscv-ai-accelerator): the CPU on its own
- [neurocore-accel](https://github.com/SandyGowda-op/neurocore-accel): the accelerator on its own
- [tpu_research](https://github.com/SandyGowda-op/tpu_research): systolic-array GEMM study

## License

MIT
