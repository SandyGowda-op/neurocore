# Docs

Design notes written while building NeuroCore. Read the top-level README first;
it holds the current, measured state of the project. Some of these documents
were written earlier and describe the design as it was at the time.

| Folder | What's in it |
|---|---|
| `isa/` | The custom-0 instructions (`FMAC_SETDESC`, `FMAC_START`, `FMAC_READ`, `RELU`) and the hazards around them |
| `mmio/` | Phase 1: the memory-mapped accelerator, forwarding and hazard investigations |
| `architecture/`, `adr/`, `overview/` | Descriptor memory, descriptor fetch, CPU/accelerator synchronisation |
| `why_we_did_it/` | Short design-decision records (why descriptors, DMA, scratchpad, ...) |
| `reports/` | Benchmark and synthesis reports from earlier phases |
| `verification/` | Verification **plans** |
| `learning/` | Study notes on the SystemVerilog and architecture concepts used here |
| `project_milestones.md`, `engineering_journal.md` | Timeline and working log |

**Note on `verification/` and `learning/`:** these describe CocoTB environments,
SVA and formal (SymbiYosys) flows as plans and study material. Those flows are
not part of the current regression. What actually runs today is listed in the
top-level README (directed tests, negative controls, multi-job and random-sweep
tests). The early SVA files are kept in `legacy/assertions/`.
