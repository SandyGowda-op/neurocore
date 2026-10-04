//==============================================================================
//
// Module      : sparse_datapath_8x8_wrapper
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   End-to-end integration wrapper for the 8x8 sparse datapath.
//
//   Dataflow:
//
//       Sparse Tile Request
//              |
//              v
//       Transfer Engine
//              |
//              v
//       Scratchpad Controller
//              |
//              v
//       Scratchpad
//        A / B / Metadata
//              |
//              v
//       Sparse Operand Readout
//              |
//              v
//       8x8 Sparse Compute Controller
//              |
//              v
//            C[8][8]
//
//   Storage:
//
//       Bank 0 -> compressed A values
//                  32 x 32-bit words
//
//       Bank 1 -> dense B values
//                  64 x 32-bit words
//
//       Bank 2 -> sparse metadata
//                  16 x 32-bit words
//
//   2:4 sparsity:
//
//       Each A row contains:
//           4 compressed values
//           2 metadata entries
//
//       Total:
//           A        = 8 x 4  = 32 values
//           Metadata = 8 x 2  = 16 values
//           B        = 8 x 8  = 64 values
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

import tile_pkg::*;

module sparse_datapath_8x8_wrapper #(

    parameter integer BURST_BYTES     = 128,
    parameter integer DATA_WIDTH      = 64,
    parameter integer SPAD_DATA_WIDTH = 32,
    parameter integer SPAD_ADDR_WIDTH = 6,
    parameter bit     VERBOSE         = 1'b0

)(

    //--------------------------------------------------------------------------
    // Global
    //--------------------------------------------------------------------------

    input logic clk,
    input logic rst,

    //--------------------------------------------------------------------------
    // Sparse Scheduler Interface
    //--------------------------------------------------------------------------

    input  sparse_tile_request_t sparse_tile_request,
    input  logic                 sparse_tile_request_valid,
    output logic                 sparse_tile_request_ready,

    //--------------------------------------------------------------------------
    // Main Memory Interface
    //--------------------------------------------------------------------------

    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_bytes,

    input  logic        mem_rvalid,
    input  logic [63:0] mem_rdata,
    input  logic        mem_rlast,

    //--------------------------------------------------------------------------
    // Sparse Compute Control
    //--------------------------------------------------------------------------

    input  logic compute_start,

    output logic compute_busy,
    output logic compute_done,

    output logic signed [63:0] compute_result [0:7][0:7],

    output logic [31:0] compute_mac_count,

    //--------------------------------------------------------------------------
    // Status
    //--------------------------------------------------------------------------

    output logic transfer_busy,
    output logic transfer_done,

    output logic datapath_busy,
    output logic datapath_done

);

    //==========================================================================
    // Parameter Checks
    //==========================================================================

    initial begin

        if (DATA_WIDTH != 64)
            $fatal(
                "sparse_datapath_8x8_wrapper: DATA_WIDTH must currently be 64"
            );

        if (SPAD_DATA_WIDTH != 32)
            $fatal(
                "sparse_datapath_8x8_wrapper: SPAD_DATA_WIDTH must currently be 32"
            );

        if (SPAD_ADDR_WIDTH != 6)
            $fatal(
                "sparse_datapath_8x8_wrapper: SPAD_ADDR_WIDTH must currently be 6"
            );

    end

    //==========================================================================
    // Transfer Engine -> Scratchpad Controller
    //==========================================================================

    logic        te_spad_write_enable;
    logic [3:0]  te_spad_bank;
    logic [31:0] te_spad_address;
    logic [63:0] te_spad_write_data;
    logic        te_spad_ready;

    //==========================================================================
    // Transfer Completion Latch
    //
    // transfer_done is a pulse.
    //
    // The compute request can arrive after transfer_done has disappeared,
    // therefore the completion condition is retained here.
    //==========================================================================

    logic transfer_complete_latched;

    always_ff @(posedge clk) begin

        if (rst) begin

            transfer_complete_latched <= 1'b0;

        end

        else begin

            if (transfer_done)
                transfer_complete_latched <= 1'b1;

            if (compute_start &&
                transfer_complete_latched)
                transfer_complete_latched <= 1'b0;

        end

    end

    //==========================================================================
    // Transfer Engine
    //==========================================================================

    transfer_engine #(

        .BURST_BYTES(BURST_BYTES),
        .DATA_WIDTH (DATA_WIDTH)

    ) u_transfer_engine (

        .clk(clk),
        .rst(rst),

        // Dense interface disabled.
        .tile_request('0),
        .tile_request_valid(1'b0),
        .tile_request_ready(),

        // Sparse scheduler.
        .sparse_tile_request(
            sparse_tile_request
        ),

        .sparse_tile_request_valid(
            sparse_tile_request_valid
        ),

        .sparse_tile_request_ready(
            sparse_tile_request_ready
        ),

        // Main memory.
        .mem_req_valid(
            mem_req_valid
        ),

        .mem_req_ready(
            mem_req_ready
        ),

        .mem_req_addr(
            mem_req_addr
        ),

        .mem_req_bytes(
            mem_req_bytes
        ),

        .mem_rvalid(
            mem_rvalid
        ),

        .mem_rdata(
            mem_rdata
        ),

        .mem_rlast(
            mem_rlast
        ),

        // Scratchpad DMA.
        .spad_write_enable(
            te_spad_write_enable
        ),

        .spad_bank(
            te_spad_bank
        ),

        .spad_address(
            te_spad_address
        ),

        .spad_write_data(
            te_spad_write_data
        ),

        .spad_ready(
            te_spad_ready
        ),

        // Status.
        .transfer_busy(
            transfer_busy
        ),

        .transfer_done(
            transfer_done
        )

    );

    

    //==========================================================================
    // Scratchpad Controller
    //==========================================================================

    logic [1:0] scratchpad_dma_bank_sel;
    logic       scratchpad_dma_en;
    logic       scratchpad_dma_we;

    logic [SPAD_ADDR_WIDTH-1:0] scratchpad_dma_addr;
    logic [SPAD_DATA_WIDTH-1:0] scratchpad_dma_wdata;
    logic [SPAD_DATA_WIDTH-1:0] scratchpad_dma_rdata;

    scratchpad_controller #(

        .DMA_DATA_WIDTH (DATA_WIDTH),
        .SPAD_DATA_WIDTH(SPAD_DATA_WIDTH),
        .SPAD_ADDR_WIDTH(SPAD_ADDR_WIDTH)

    ) u_scratchpad_controller (

        .clk(clk),
        .rst(rst),

        .dma_write_enable(
            te_spad_write_enable
        ),

        .dma_bank(
            te_spad_bank
        ),

        .dma_address(
            te_spad_address
        ),

        .dma_write_data(
            te_spad_write_data
        ),

        .dma_ready(
            te_spad_ready
        ),

        .spad_bank_sel(
            scratchpad_dma_bank_sel
        ),

        .spad_en(
            scratchpad_dma_en
        ),

        .spad_we(
            scratchpad_dma_we
        ),

        .spad_addr(
            scratchpad_dma_addr
        ),

        .spad_wdata(
            scratchpad_dma_wdata
        )

    );

    //==========================================================================
    // Sparse Scratchpad Read Interfaces
    //==========================================================================

    logic sparse_a_en;
    logic sparse_a_we;

    logic [SPAD_ADDR_WIDTH-1:0] sparse_a_addr;

    logic [SPAD_DATA_WIDTH-1:0] sparse_a_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_a_rdata;


    logic sparse_b_en;
    logic sparse_b_we;

    logic [SPAD_ADDR_WIDTH-1:0] sparse_b_addr;

    logic [SPAD_DATA_WIDTH-1:0] sparse_b_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_b_rdata;


    logic sparse_metadata_en;
    logic sparse_metadata_we;

    logic [SPAD_ADDR_WIDTH-1:0] sparse_metadata_addr;

    logic [SPAD_DATA_WIDTH-1:0] sparse_metadata_wdata;
    logic [SPAD_DATA_WIDTH-1:0] sparse_metadata_rdata;



    //--------------------------------------------------------------------------
    // Sparse compute path is read-only.
    //--------------------------------------------------------------------------

    assign sparse_a_we           = 1'b0;
    assign sparse_a_wdata        = '0;

    assign sparse_b_we           = 1'b0;
    assign sparse_b_wdata        = '0;

    assign sparse_metadata_we    = 1'b0;
    assign sparse_metadata_wdata = '0;

    //==========================================================================
    // Scratchpad
    //==========================================================================

    logic [SPAD_DATA_WIDTH-1:0] unused_compute_rdata;

    scratchpad #(

        .DATA_WIDTH(SPAD_DATA_WIDTH),
        .MATRIX_DIM(8),
        .DEPTH(64),
        .ADDR_WIDTH(SPAD_ADDR_WIDTH)

    ) u_scratchpad (

        .clk(clk),
        .rst(rst),

        // DMA interface.
        .dma_bank_sel(
            scratchpad_dma_bank_sel
        ),

        .dma_en(
            scratchpad_dma_en
        ),

        .dma_we(
            scratchpad_dma_we
        ),

        .dma_addr(
            scratchpad_dma_addr
        ),

        .dma_wdata(
            scratchpad_dma_wdata
        ),

        .dma_rdata(
            scratchpad_dma_rdata
        ),

        // Existing dense compute interface disabled.
        .compute_bank_sel(2'b00),
        .compute_en(1'b0),
        .compute_we(1'b0),
        .compute_addr('0),
        .compute_wdata('0),
        .compute_rdata(unused_compute_rdata),

        // Sparse A.
        .sparse_a_en(
            sparse_a_en
        ),

        .sparse_a_we(
            sparse_a_we
        ),

        .sparse_a_addr(
            sparse_a_addr
        ),

        .sparse_a_wdata(
            sparse_a_wdata
        ),

        .sparse_a_rdata(
            sparse_a_rdata
        ),

        // Sparse B.
        .sparse_b_en(
            sparse_b_en
        ),

        .sparse_b_we(
            sparse_b_we
        ),

        .sparse_b_addr(
            sparse_b_addr
        ),

        .sparse_b_wdata(
            sparse_b_wdata
        ),

        .sparse_b_rdata(
            sparse_b_rdata
        ),

        // Sparse metadata.
        .sparse_metadata_en(
            sparse_metadata_en
        ),

        .sparse_metadata_we(
            sparse_metadata_we
        ),

        .sparse_metadata_addr(
            sparse_metadata_addr
        ),

        .sparse_metadata_wdata(
            sparse_metadata_wdata
        ),

        .sparse_metadata_rdata(
            sparse_metadata_rdata
        )

    );

    //==========================================================================
    // Captured Sparse Operands
    //==========================================================================

    logic signed [31:0] sparse_a [0:7][0:3];

    logic signed [31:0] dense_b [0:7][0:7];

    logic [2:0] sparse_metadata [0:7][0:1];

    //==========================================================================
    // Sparse Read FSM
    //
    // The scratchpad sparse read path is registered.
    //
    // Timing:
    //
    //   READ_REQUEST
    //        |
    //        v
    //   WAIT1
    //        |
    //        v
    //   WAIT2
    //        |
    //        v
    //   WAIT3
    //        |
    //        v
    //      CAPTURE
    //
    // WAIT3 is therefore intentional.
    //==========================================================================

    typedef enum logic [3:0] {

        READ_IDLE,

        READ_A_REQUEST,
        READ_A_WAIT1,
        READ_A_WAIT2,
        READ_A_WAIT3,

        READ_B_REQUEST,
        READ_B_WAIT1,
        READ_B_WAIT2,
        READ_B_WAIT3,

        READ_META_REQUEST,
        READ_META_WAIT1,
        READ_META_WAIT2,
        READ_META_WAIT3,

        READ_COMPLETE,
        COMPUTE_WAIT

    } read_state_t;

    read_state_t read_state;

    logic [5:0] read_index;

    always @(posedge clk) begin
    if (!rst && VERBOSE) begin
        $display(
            "[READDBG] t=%0t start=%b latch=%b state=%0d A_en=%b B_en=%b META_en=%b",
            $time,
            compute_start,
            transfer_complete_latched,
            read_state,
            sparse_a_en,
            sparse_b_en,
            sparse_metadata_en
        );
    end
end

    //==========================================================================
    // Sparse Read Address Generation
    //==========================================================================

    always_comb begin

        sparse_a_en          = 1'b0;
        sparse_a_addr        = '0;

        sparse_b_en          = 1'b0;
        sparse_b_addr        = '0;

        sparse_metadata_en   = 1'b0;
        sparse_metadata_addr = '0;

        case (read_state)

            //------------------------------------------------------------------
            // Compressed A
            //------------------------------------------------------------------

            READ_A_REQUEST: begin

                sparse_a_en   = 1'b1;
                sparse_a_addr = read_index;

            end

            //------------------------------------------------------------------
            // Dense B
            //------------------------------------------------------------------

            READ_B_REQUEST: begin

                sparse_b_en   = 1'b1;
                sparse_b_addr = read_index;

            end

            //------------------------------------------------------------------
            // Metadata
            //------------------------------------------------------------------

            READ_META_REQUEST: begin

                sparse_metadata_en   = 1'b1;
                sparse_metadata_addr = read_index;

            end

            default: begin

            end

        endcase

    end

    //==========================================================================
    // Sparse Operand Read Controller
    //==========================================================================

    integer r;
    integer c;

    always_ff @(posedge clk) begin

        if (rst) begin

            read_state <= READ_IDLE;
            read_index <= 6'd0;

            for (r = 0; r < 8; r = r + 1) begin

                for (c = 0; c < 4; c = c + 1)
                    sparse_a[r][c] <= '0;

                for (c = 0; c < 8; c = c + 1)
                    dense_b[r][c] <= '0;

                for (c = 0; c < 2; c = c + 1)
                    sparse_metadata[r][c] <= '0;

            end

        end

        else begin

            case (read_state)

                //==============================================================
                // Wait for compute request.
                //==============================================================

                READ_IDLE: begin

                    if (compute_start &&
                        transfer_complete_latched) begin

                        read_index <= 6'd0;

                        read_state <= READ_A_REQUEST;

                    end

                end

                //==============================================================
                // A
                //==============================================================

                READ_A_REQUEST: begin

                    read_state <= READ_A_WAIT1;

                end


                READ_A_WAIT1: begin

                    read_state <= READ_A_WAIT2;

                end


                READ_A_WAIT2: begin

                    read_state <= READ_A_WAIT3;

                end


                READ_A_WAIT3: begin

                    sparse_a[
                        read_index / 4
                    ][
                        read_index % 4
                    ] <= sparse_a_rdata;

                    if (read_index == 6'd31) begin

                        read_index <= 6'd0;

                        read_state <= READ_B_REQUEST;

                    end

                    else begin

                        read_index <= read_index + 6'd1;

                        read_state <= READ_A_REQUEST;

                    end

                end

                //==============================================================
                // B
                //==============================================================

                READ_B_REQUEST: begin

                    read_state <= READ_B_WAIT1;

                end


                READ_B_WAIT1: begin

                    read_state <= READ_B_WAIT2;

                end


                READ_B_WAIT2: begin

                    read_state <= READ_B_WAIT3;

                end


                READ_B_WAIT3: begin

                    dense_b[
                        read_index / 8
                    ][
                        read_index % 8
                    ] <= sparse_b_rdata;

                    if (read_index == 6'd63) begin

                        read_index <= 6'd0;

                        read_state <= READ_META_REQUEST;

                    end

                    else begin

                        read_index <= read_index + 6'd1;

                        read_state <= READ_B_REQUEST;

                    end

                end

                //==============================================================
                // Metadata
                //==============================================================

                READ_META_REQUEST: begin

                    read_state <= READ_META_WAIT1;

                end


                READ_META_WAIT1: begin

                    read_state <= READ_META_WAIT2;

                end


                READ_META_WAIT2: begin

                    read_state <= READ_META_WAIT3;

                end


                READ_META_WAIT3: begin

                    sparse_metadata[
                        read_index / 2
                    ][
                        read_index % 2
                    ] <= sparse_metadata_rdata[2:0];

                    if (read_index == 6'd15) begin

                        read_state <= READ_COMPLETE;

                    end

                    else begin

                        read_index <= read_index + 6'd1;

                        read_state <= READ_META_REQUEST;

                    end

                end

                //==============================================================
                // All operands captured.
                //==============================================================

                READ_COMPLETE: begin

                    read_state <= COMPUTE_WAIT;

                end

                //==============================================================
                // Compute active.
                //==============================================================

                COMPUTE_WAIT: begin

                    if (compute_done)
                        read_state <= READ_IDLE;

                end

                //==============================================================
                // Safety.
                //==============================================================

                default: begin

                    read_state <= READ_IDLE;
                    read_index <= 6'd0;

                end

            endcase

        end

    end

    //==========================================================================
    // Sparse Compute Start
    //==========================================================================

    logic sparse_compute_start;

    assign sparse_compute_start =
        (read_state == READ_COMPLETE);

    //==========================================================================
    // Sparse 8x8 Compute Controller
    //==========================================================================

    logic [15:0] sparse_mac_count;

    sparse_compute_8x8_controller #(

        .DATA_WIDTH(32),
        .ACC_WIDTH(64)

    ) u_sparse_compute_8x8 (

        .clk(clk),
        .rst(rst),

        .start(
            sparse_compute_start
        ),

        .busy(
            compute_busy
        ),

        .done(
            compute_done
        ),

        // Compressed A.
        .sparse_a(
            sparse_a
        ),

        // Dense B.
        .b(
            dense_b
        ),

        // Metadata.
        .metadata(
            sparse_metadata
        ),

        // Result.
        .result(
            compute_result
        ),

        // Executed MAC count.
        .mac_count(
            sparse_mac_count
        )

    );

    //==========================================================================
    // MAC Count
    //==========================================================================

    always_comb begin

        compute_mac_count = {16'd0, sparse_mac_count};

    end

    //==========================================================================
    // Datapath Status
    //==========================================================================

    always_comb begin

        datapath_busy =
            transfer_busy ||
            compute_busy ||
            (read_state != READ_IDLE);

        datapath_done =
            compute_done;

    end


always @(posedge clk) begin
    if (mem_rvalid && VERBOSE) begin
        $display(
            "[MEM->DMA] t=%0t addr=%08h data=%016h last=%b",
            $time,
            mem_req_addr,
            mem_rdata,
            mem_rlast
        );
    end
end


endmodule

`default_nettype wire