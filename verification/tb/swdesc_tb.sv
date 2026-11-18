//==============================================================================
// swdesc_tb : T6 -- CPU-authored descriptors (SW to 0x2000 window) + store/fetch hazard
//   +TEST=a  CPU builds desc 4 with 8 SW (operands ready early), runs it
//   +TEST=b  CPU builds desc 5 with ADDI/LUI->SW back-to-back (store-data forwarding)
//   +TEST=c  START (desc 0, TB-preloaded) immediately followed by a corrupting SW
// Golden: gold_arrays.svh (same coordinated sparse/dense A x B as riscv_pipeline_tb).
//==============================================================================
`timescale 1ns/1ps
module swdesc_tb;
    localparam time CLK_PERIOD = 10ns;
    reg clk = 1'b0, rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg desc_we = 1'b0; reg [6:0] desc_idx = 0; reg [2:0] desc_word_off = 0; reg [31:0] desc_wdata = 0;
    wire mmul_busy, mmul_done, dbg_accel_busy;
    wire [31:0] dbg_pc, dbg_instr, dbg_alu, dbg_dmem_load;
    wire [31:0] dbg_r1, dbg_r2, dbg_r3, dbg_r4, dbg_r5, dbg_r6, dbg_r7, dbg_r8, dbg_r9;

    riscv_pipeline dut (
        .clk(clk), .rst(rst), .mmul_busy(mmul_busy), .mmul_done(mmul_done),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_alu(dbg_alu), .dbg_dmem_load(dbg_dmem_load),
        .dbg_r1(dbg_r1), .dbg_r2(dbg_r2), .dbg_r3(dbg_r3), .dbg_r4(dbg_r4), .dbg_r5(dbg_r5),
        .dbg_r6(dbg_r6), .dbg_r7(dbg_r7), .dbg_r8(dbg_r8), .dbg_r9(dbg_r9), .dbg_accel_busy(dbg_accel_busy),
        .desc_we(desc_we), .desc_idx(desc_idx), .desc_word_off(desc_word_off), .desc_wdata(desc_wdata));

    reg signed [63:0] exp_sp [0:63];
    reg signed [63:0] exp_de [0:63];
`include "gold_arrays.svh"

    task automatic wword(input [2:0] off, input [31:0] d);
        begin @(posedge clk); desc_we <= 1; desc_idx <= 7'd0; desc_word_off <= off; desc_wdata <= d;
              @(posedge clk); desc_we <= 0; end
    endtask

    integer errs = 0, done_pulses = 0, run_pulses = 0, sel_pulses = 0, test = 0, cyc = 0;
    reg [8*8-1:0] tname;
    reg [255:0] tag;
    // log every CPU-authored descriptor word as it commits (idx / word offset / data)
    always @(posedge clk) if (!rst && dut.desc_sel)
        $display("DESCW t=%0t idx=%0d off=%0d data=%08h", $time, dut.exmem_alu[11:5], dut.exmem_alu[4:2], dut.exmem_rs2);

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (!rst) begin
            if (dut.accelerator_all_done) done_pulses = done_pulses + 1;
            if (dut.accelerator_run)      run_pulses  = run_pulses + 1;
            if (dut.desc_sel)             sel_pulses  = sel_pulses + 1;
        end
    end

    task automatic chk64(input [511:0] what, input integer r, input signed [63:0] exp);
        reg signed [63:0] got;
        begin
            got = $signed(dut.rf.regs[r]);
            if (got !== exp) begin errs = errs + 1; $display("  [FAIL] %0s x%0d got %0d exp %0d", what, r, got, exp); end
            else $display("  [ OK ] %0s x%0d = %0d", what, r, got);
        end
    endtask
    task automatic chki(input [511:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin errs = errs + 1; $display("  [FAIL] %0s got %0d exp %0d", what, got, exp); end
            else $display("  [ OK ] %0s = %0d", what, got);
        end
    endtask

    initial begin
        if ($test$plusargs("TEST_a")) test = 1; else if ($test$plusargs("TEST_b")) test = 2; else test = 3;
        repeat (4) @(posedge clk); rst = 1'b0;
        // desc 0 (sparse, window 0) preloaded over the TB bus -- used by test c only
        wword(0, 32'h1000_0000); wword(1, 32'h1000_0100); wword(2, 32'h1000_0200); wword(3, 32'h1000_0300);
        wword(4, {16'd8,16'd8}); wword(5, {16'd8,16'd32}); wword(6, {16'd32,16'd32}); wword(7, 32'h0000_0401);
        fork
            begin wait (done_pulses >= 1); repeat (80) @(posedge clk); end
            begin repeat (30000) @(posedge clk); $display("[FAIL] TIMEOUT pc=%08h", dbg_pc); errs = errs + 1; end
        join_any
        $display("---- T6 (%s) ----", test == 1 ? "a: SW-authored descriptor" : test == 2 ? "b: store-data forwarding" : "c: SW behind START");
        chki("run pulses", run_pulses, 1);
        chki("all_done pulses", done_pulses, 1);
        if (test == 1 || test == 2) begin
            chki("descriptor stores committed (desc_sel pulses)", sel_pulses, 8);
            chk64("C[0] ", 20, exp_sp[0]); chk64("C[9] ", 21, exp_sp[9]); chk64("C[63]", 22, exp_sp[63]);
            chki("status error bit", dut.rf.regs[23] & 3, 0);
        end else begin
            chki("descriptor stores committed (desc_sel pulses)", sel_pulses, 1);
            chk64("C[0] ", 10, exp_sp[0]); chk64("C[9] ", 11, exp_sp[9]);
            chki("status error bit", dut.rf.regs[13] & 3, 0);
        end
        if (errs == 0) $display("T6 RESULT: PASS"); else $display("T6 RESULT: FAIL (%0d)", errs);
        $finish;
    end
endmodule