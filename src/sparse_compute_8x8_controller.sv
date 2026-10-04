//==============================================================================
//
// Module      : sparse_compute_8x8_controller
// Project     : Descriptor-Driven RISC-V AI Accelerator
//
// Description :
//   Complete 8x8 sparse matrix multiplication controller using 2:4
//   structured sparsity.
//
//   Computes:
//
//       C[8x8] = A[8x8] x B[8x8]
//
//   A is supplied in compressed 2:4 format:
//
//       Each A row:
//           group 0 -> 2 compressed values + 3-bit metadata
//           group 1 -> 2 compressed values + 3-bit metadata
//
//       8 rows x 4 compressed values = 32 A values
//       8 rows x 2 metadata groups  = 16 metadata values
//
//   B is supplied as a dense 8x8 matrix.
//
//   A single MAC unit is reused sequentially.
//
//   Dense MAC operations:
//       8 x 8 x 8 = 512
//
//   Sparse MAC operations:
//       8 x 8 x 4 = 256
//
//==============================================================================

`timescale 1ns/1ps
`default_nettype none

module sparse_compute_8x8_controller #(

    parameter int DATA_WIDTH = 32,
    parameter int ACC_WIDTH  = 64

)(

    //--------------------------------------------------------------------------
    // Global
    //--------------------------------------------------------------------------

    input logic clk,
    input logic rst,

    //--------------------------------------------------------------------------
    // Control
    //--------------------------------------------------------------------------

    input  logic start,
    output logic busy,
    output logic done,

    //--------------------------------------------------------------------------
    // Compressed A
    //
    // sparse_a[row][0] -> first non-zero of group 0
    // sparse_a[row][1] -> second non-zero of group 0
    // sparse_a[row][2] -> first non-zero of group 1
    // sparse_a[row][3] -> second non-zero of group 1
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] sparse_a [0:7][0:3],

    //--------------------------------------------------------------------------
    // Dense B
    //
    // b[k][column]
    //--------------------------------------------------------------------------

    input logic signed [DATA_WIDTH-1:0] b [0:7][0:7],

    //--------------------------------------------------------------------------
    // Metadata
    //
    // metadata[row][0] -> A[row][0:3]
    // metadata[row][1] -> A[row][4:7]
    //--------------------------------------------------------------------------

    input logic [2:0] metadata [0:7][0:1],

    //--------------------------------------------------------------------------
    // Result
    //--------------------------------------------------------------------------

    output logic signed [ACC_WIDTH-1:0] result [0:7][0:7],

    //--------------------------------------------------------------------------
    // Verification Metric
    //
    // Total number of executed sparse MAC operations.
    //--------------------------------------------------------------------------

    output logic [15:0] mac_count

);

    //==========================================================================
    // Parameter Checks
    //==========================================================================

    initial begin

        if (DATA_WIDTH <= 0)
            $fatal(
                "sparse_compute_8x8_controller: DATA_WIDTH must be > 0"
            );

        if (ACC_WIDTH <= 0)
            $fatal(
                "sparse_compute_8x8_controller: ACC_WIDTH must be > 0"
            );

    end

    //==========================================================================
    // State Machine
    //==========================================================================

    typedef enum logic [3:0] {

        IDLE,

        CLEAR_ACC,

        MAC_FIRST,
        MAC_SECOND,

        NEXT_GROUP,

        STORE_RESULT,

        NEXT_COLUMN,
        NEXT_ROW,

        COMPLETE

    } state_t;

    state_t state;

    //==========================================================================
    // Iteration Counters
    //==========================================================================

    logic [2:0] current_row;
    logic [2:0] current_col;

    // 0 -> K 0..3
    // 1 -> K 4..7
    logic       current_group;

    //==========================================================================
    // Metadata Decoder
    //==========================================================================

    logic [3:0] metadata_enable_mask;
    logic [1:0] metadata_index0;
    logic [1:0] metadata_index1;

    metadata_decoder u_metadata_decoder (

        .metadata(
            metadata[current_row][current_group]
        ),

        .enable_mask(
            metadata_enable_mask
        ),

        .index0(
            metadata_index0
        ),

        .index1(
            metadata_index1
        )

    );

    //==========================================================================
    // Logical K Indices
    //==========================================================================

    logic [2:0] logical_k0;
    logic [2:0] logical_k1;

    always_comb begin

        if (current_group == 1'b0) begin

            logical_k0 =
                {1'b0, metadata_index0};

            logical_k1 =
                {1'b0, metadata_index1};

        end

        else begin

            logical_k0 =
                3'd4 + {1'b0, metadata_index0};

            logical_k1 =
                3'd4 + {1'b0, metadata_index1};

        end

    end

    //==========================================================================
    // Compressed A Indices
    //==========================================================================

    logic [1:0] compressed_a_index0;
    logic [1:0] compressed_a_index1;

    always_comb begin

        if (current_group == 1'b0) begin

            compressed_a_index0 = 2'd0;
            compressed_a_index1 = 2'd1;

        end

        else begin

            compressed_a_index0 = 2'd2;
            compressed_a_index1 = 2'd3;

        end

    end

    //==========================================================================
    // MAC Operands
    //==========================================================================

    logic signed [DATA_WIDTH-1:0] mac_operand_a;
    logic signed [DATA_WIDTH-1:0] mac_operand_b;

    always_comb begin

        mac_operand_a = '0;
        mac_operand_b = '0;

        case (state)

            //------------------------------------------------------------------
            // First non-zero value in current 2:4 group
            //------------------------------------------------------------------

            MAC_FIRST: begin

                mac_operand_a =
                    sparse_a[current_row][compressed_a_index0];

                mac_operand_b =
                    b[logical_k0][current_col];

            end

            //------------------------------------------------------------------
            // Second non-zero value in current 2:4 group
            //------------------------------------------------------------------

            MAC_SECOND: begin

                mac_operand_a =
                    sparse_a[current_row][compressed_a_index1];

                mac_operand_b =
                    b[logical_k1][current_col];

            end

            default: begin

                mac_operand_a = '0;
                mac_operand_b = '0;

            end

        endcase

    end

    //==========================================================================
    // MAC Unit
    //==========================================================================

    logic mac_enable;
    logic clear_acc;

    logic signed [ACC_WIDTH-1:0] mac_accumulator;

    mac_unit #(

        .OPERAND_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)

    ) u_mac (

        .clk(clk),
        .rst(rst),

        .enable(mac_enable),
        .clear_acc(clear_acc),

        .operand_a(mac_operand_a),
        .operand_b(mac_operand_b),

        .accumulator(mac_accumulator)

    );

    //==========================================================================
    // MAC Control
    //==========================================================================

    always_comb begin

        mac_enable = 1'b0;
        clear_acc  = 1'b0;

        case (state)

            //------------------------------------------------------------------
            // Clear accumulator before EVERY C[row][col].
            //------------------------------------------------------------------

            CLEAR_ACC: begin

                clear_acc = 1'b1;

            end

            //------------------------------------------------------------------
            // One MAC per cycle.
            //------------------------------------------------------------------

            MAC_FIRST,
            MAC_SECOND: begin

                mac_enable = 1'b1;

            end

            default: begin

                mac_enable = 1'b0;
                clear_acc  = 1'b0;

            end

        endcase

    end

    //==========================================================================
    // Controller
    //==========================================================================

    integer row_index;
    integer col_index;

    always_ff @(posedge clk) begin

        if (rst) begin

            state <= IDLE;

            current_row   <= 3'd0;
            current_col   <= 3'd0;
            current_group <= 1'b0;

            busy <= 1'b0;
            done <= 1'b0;

            mac_count <= 16'd0;

            for (row_index = 0;
                 row_index < 8;
                 row_index = row_index + 1) begin

                for (col_index = 0;
                     col_index < 8;
                     col_index = col_index + 1) begin

                    result[row_index][col_index] <= '0;

                end

            end

        end

        else begin

            // done is a one-cycle pulse.
            done <= 1'b0;

            case (state)

                //================================================================
                // IDLE
                //================================================================

                IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        busy <= 1'b1;

                        current_row   <= 3'd0;
                        current_col   <= 3'd0;
                        current_group <= 1'b0;

                        mac_count <= 16'd0;

                        state <= CLEAR_ACC;

                    end

                end

                //================================================================
                // CLEAR ACCUMULATOR
                //
                // This occurs once before EVERY output C[row][col].
                //================================================================

                CLEAR_ACC: begin

                    state <= MAC_FIRST;

                end

                //================================================================
                // First MAC of current 2:4 group
                //================================================================

                MAC_FIRST: begin

                    mac_count <= mac_count + 16'd1;

                    state <= MAC_SECOND;

                end

                //================================================================
                // Second MAC of current 2:4 group
                //================================================================

                MAC_SECOND: begin

                    mac_count <= mac_count + 16'd1;

                    state <= NEXT_GROUP;

                end

                //================================================================
                // Advance sparse K group
                //================================================================

                NEXT_GROUP: begin

                    if (current_group == 1'b0) begin

                        // Group 0 complete.
                        // Start group 1.

                        current_group <= 1'b1;

                        state <= MAC_FIRST;

                    end

                    else begin

                        // Both groups complete.
                        // The accumulator now contains the complete
                        // C[row][col] value.

                        state <= STORE_RESULT;

                    end

                end

                //================================================================
                // Store current output element
                //================================================================

                STORE_RESULT: begin

                    result[current_row][current_col]
                        <= mac_accumulator;

                    current_group <= 1'b0;

                    state <= NEXT_COLUMN;

                end

                //================================================================
                // Advance output column
                //================================================================

                NEXT_COLUMN: begin

                    if (current_col < 3'd7) begin

                        current_col <= current_col + 3'd1;

                        state <= CLEAR_ACC;

                    end

                    else begin

                        current_col <= 3'd0;

                        state <= NEXT_ROW;

                    end

                end

                //================================================================
                // Advance output row
                //================================================================

                NEXT_ROW: begin

                    if (current_row < 3'd7) begin

                        current_row <= current_row + 3'd1;

                        state <= CLEAR_ACC;

                    end

                    else begin

                        state <= COMPLETE;

                    end

                end

                //================================================================
                // COMPLETE
                //================================================================

                COMPLETE: begin

                    busy <= 1'b0;
                    done <= 1'b1;

                    state <= IDLE;

                end

                //================================================================
                // Safety
                //================================================================

                default: begin

                    state <= IDLE;

                    busy <= 1'b0;
                    done <= 1'b0;

                    current_row   <= 3'd0;
                    current_col   <= 3'd0;
                    current_group <= 1'b0;

                end

            endcase

        end

    end

endmodule

`default_nettype wire