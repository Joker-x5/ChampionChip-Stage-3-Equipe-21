`timescale 1ns / 1ps
// =============================================================================
// ChampionChip Phase 3 - PIN Controller (GPIO)
// =============================================================================
// Description:
//   Memory-mapped 8-bit bidirectional GPIO controller per Section 1 of BlockGuide.
//   Base Address: 0xF0000000
//
// Register Map:
//   Offset 0x0000 (DATAOUT): RW - [7:0] Logic level for output pins
//   Offset 0x0004 (DATAIN) : R  - [7:0] Logic level read from input pins
//   Offset 0x0008 (DATADIR): RW - [7:0] Pin direction (0 = Input, 1 = Output)
//
// Direct Interface with ChipInventor "Inout Pin" Block:
//   - datadir [7:0] : Direction control (Connects to 'C' of Inout Pin)
//   - dataout [7:0] : Output drive data (Connects to 'D' of Inout Pin)
//   - datain  [7:0] : Sampled external input data (Connects from Right Circle of Inout Pin)
//
// Contention Isolation (Section 1.3.1 & Figure 1):
//   - Output mode (DATADIR[i] = 1): drives 'd', input buffer is isolated (forces 0).
//   - Input mode  (DATADIR[i] = 0): 'c' is 0 (high-Z pad), samples external pin level into DATAIN.
// =============================================================================

module gpio (
    input  wire        clk_i,
    input  wire        rst_i,

    // Bus Interface (32-bit aligned addresses)
    input  wire [31:0] addr_i,
    input  wire [31:0] data_i,
    input  wire        we_i,
    input  wire        oe_i,
    output reg  [31:0] data_o,

    // Direct interface to ChipInventor "Inout Pin" Block (C, D, and Data In)
    output reg  [7:0]  datadir, // Direction control -> Connects to 'C' on Inout Pin
    output reg  [7:0]  dataout, // Output drive data -> Connects to 'D' on Inout Pin
    input  wire [7:0]  datain   // Sampled data in   <- Connects from Right Circle on Inout Pin
);

    // Internal Register for Input Sampling Flip-Flop (Section 1.3.1, Figure 1)
    reg [7:0] r_datain;

    // Address Decoding (Word-aligned: uses addr_i[3:2])
    // Offset 0x00 (0b00) = DATAOUT
    // Offset 0x04 (0b01) = DATAIN
    // Offset 0x08 (0b10) = DATADIR
    wire [1:0] reg_offset = addr_i[3:2];

    // -------------------------------------------------------------------------
    // 1. Bus Write Operations (Directly registers datadir and dataout)
    // -------------------------------------------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) begin
            dataout <= 8'h00;
            datadir <= 8'h00; // Default: all pins configured as inputs (safe)
        end else if (we_i) begin
            case (reg_offset)
                2'b00: dataout <= data_i[7:0];
                2'b10: datadir <= data_i[7:0];
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. Bus Read Operations (Synchronous / Latched read, zero-extended to 32 bits)
    // -------------------------------------------------------------------------
    always @(*) begin
        if (oe_i) begin
            case (reg_offset)
                2'b00:   data_o = {24'd0, dataout};
                2'b01:   data_o = {24'd0, r_datain};
                2'b10:   data_o = {24'd0, datadir};
                default: data_o = 32'd0;
            endcase
        end else begin
            data_o = 32'd0;
        end
    end

    // -------------------------------------------------------------------------
    // 3. Input Buffer Sampling with Contention Isolation (Section 1.3.1, Figure 1)
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_input_sampling
            always @(posedge clk_i) begin
                if (rst_i) begin
                    r_datain[i] <= 1'b0;
                end else if (datadir[i] == 1'b0) begin
                    // Sample external pin level when in input mode
                    r_datain[i] <= datain[i];
                end else begin
                    // Isolated in output mode to prevent output driving feedback
                    r_datain[i] <= 1'b0;
                end
            end
        end
    endgenerate

endmodule
