# legacy/

Kept for history; none of this is part of the build or the regression.

| Path | What it is |
|---|---|
| `rtl/` | modules no longer instantiated (`alu.v`, `alu_control.v`, `mmul_controller.sv`, `sparse_scheduler.sv`, `tile_buffers.sv`) |
| `tb/` | testbenches for interfaces that no longer exist (`descriptor_fetch_unit_tb.sv`, `riscv_pipeline_tb_cpu.v`) |
| `assertions/`, `binds/` | early SVA properties for the descriptor fetch unit; written and tried on EDA Playground, not yet running in this regression |
| `old_flow/` | the Phase-1 Vivado/OpenSTA flow scripts and constraints |
