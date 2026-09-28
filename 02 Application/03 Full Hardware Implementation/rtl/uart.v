`timescale 1ns / 1ps
// =============================================================================
// ChampionChip Phase 3 - Serial Controller (UART)
// =============================================================================
// Description:
//   Memory-mapped 8-N-1 full-duplex UART controller per Section 2 of BlockGuide.
//   Base Address: 0xF1000000
//
// Register Map:
//   Offset 0x0000 (TXDATA) : RW - [7:0] Byte to be transmitted
//   Offset 0x0004 (RXDATA) : R  - [7:0] Received byte
//   Offset 0x0008 (CONTROL): Status & control register
//     Bit 0: TRANSMIT (W)  - 1 starts transmission from TXDATA. Cleared next cycle.
//     Bit 1: RXDONE   (RW) - 1 indicates reception complete. Cleared by writing 0.
//     Bit 2: TXDONE   (R)  - 1 indicates transmitter idle / transmission complete.
//     Bits [31:3]: Reserved (0)
//
// Protocol:
//   - Baud Rate: 115,200 bps (parameterized with CLK_FREQ, default 50 MHz)
//   - Frame: 1 Start bit ('0'), 8 Data bits (LSB first), 1 Stop bit ('1')
//   - Direct baud midpoint sampling (no oversampling)
//   - Double-flop synchronizer on rx_i to prevent metastability
// =============================================================================

module uart #(
    parameter CLK_FREQ         = 50_000_000,
    parameter BAUD_RATE        = 115200,
    parameter AUTO_TX_ON_WRITE = 1
)(
    input  wire        clk_i,
    input  wire        rst_i,

    // Bus Interface (32-bit aligned addresses)
    input  wire [31:0] addr_i,
    input  wire [31:0] data_i,
    input  wire        we_i,
    input  wire        oe_i,
    output reg  [31:0] data_o,

    // External Serial Interface
    output reg         tx_o,
    input  wire        rx_i
);

    // Clock cycles per UART bit
    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    // Address Decoding (Word-aligned: uses addr_i[3:2])
    // Offset 0x00 (0b00) = TXDATA
    // Offset 0x04 (0b01) = RXDATA
    // Offset 0x08 (0b10) = CONTROL
    wire [1:0] reg_offset = addr_i[3:2];

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    reg [7:0]  r_txdata;
    reg [7:0]  r_rxdata;
    reg        r_rxdone;
    reg        r_txdone;
    reg        r_transmit;

    // Shift registers
    reg [7:0]  FIFOtx;
    reg [7:0]  FIFOrx;

    // Receiver pulse
    reg        rx_done_pulse;

    // -------------------------------------------------------------------------
    // Double-Flop Synchronizer for rx_i (metastability protection)
    // -------------------------------------------------------------------------
    reg rx_sync1;
    reg rx_sync2;

    always @(posedge clk_i) begin
        if (rst_i) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx_i;
            rx_sync2 <= rx_sync1;
        end
    end

    // -------------------------------------------------------------------------
    // Transmitter FSM
    // -------------------------------------------------------------------------
    localparam TX_IDLE  = 2'd0;
    localparam TX_START = 2'd1;
    localparam TX_DATA  = 2'd2;
    localparam TX_STOP  = 2'd3;

    reg [1:0]  tx_state;
    reg [15:0] tx_clk_cnt;
    reg [2:0]  tx_bit_idx;

    // Transmit trigger:
    // 1. Setting TRANSMIT bit (bit 0) in CONTROL register (Section 2.2.3 & 2.3.1)
    // 2. Writing to TXDATA when AUTO_TX_ON_WRITE is enabled (Section 2.3.3 & Page 12)
    wire tx_start_req = (we_i && (reg_offset == 2'b10) && data_i[0]) ||
                        (AUTO_TX_ON_WRITE && we_i && (reg_offset == 2'b00));

    always @(posedge clk_i) begin
        if (rst_i) begin
            tx_state   <= TX_IDLE;
            tx_clk_cnt <= 16'd0;
            tx_bit_idx <= 3'd0;
            tx_o       <= 1'b1; // Idle line is HIGH
            r_txdone   <= 1'b1; // Ready to transmit on reset
            FIFOtx     <= 8'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx_o       <= 1'b1;
                    tx_clk_cnt <= 16'd0;
                    tx_bit_idx <= 3'd0;
                    if (tx_start_req) begin
                        // Load data into transmitter FIFO
                        FIFOtx     <= (we_i && (reg_offset == 2'b00)) ? data_i[7:0] : r_txdata;
                        tx_o       <= 1'b0; // Drive Start bit ('0')
                        r_txdone   <= 1'b0; // Clear TXDONE while transmitting
                        tx_state   <= TX_START;
                    end else begin
                        r_txdone   <= 1'b1;
                    end
                end

                TX_START: begin
                    tx_o <= 1'b0; // Hold Start bit
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1'b1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        tx_o       <= FIFOtx[0]; // Drive first data bit
                        tx_bit_idx <= 3'd0;
                        tx_state   <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx_o <= FIFOtx[tx_bit_idx];
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1'b1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        if (tx_bit_idx < 3'd7) begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                            tx_o       <= FIFOtx[tx_bit_idx + 1'b1];
                        end else begin
                            tx_o     <= 1'b1; // Drive Stop bit ('1')
                            tx_state <= TX_STOP;
                        end
                    end
                end

                TX_STOP: begin
                    tx_o <= 1'b1; // Hold Stop bit
                    if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                        tx_clk_cnt <= tx_clk_cnt + 1'b1;
                    end else begin
                        tx_clk_cnt <= 16'd0;
                        r_txdone   <= 1'b1; // Transmission complete
                        tx_state   <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Receiver FSM (Direct Baud Midpoint Sampling, No Oversampling)
    // -------------------------------------------------------------------------
    localparam RX_IDLE  = 2'd0;
    localparam RX_START = 2'd1;
    localparam RX_DATA  = 2'd2;
    localparam RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [15:0] rx_clk_cnt;
    reg [2:0]  rx_bit_idx;

    always @(posedge clk_i) begin
        if (rst_i) begin
            rx_state      <= RX_IDLE;
            rx_clk_cnt    <= 16'd0;
            rx_bit_idx    <= 3'd0;
            FIFOrx        <= 8'd0;
            r_rxdata      <= 8'd0;
            rx_done_pulse <= 1'b0;
        end else begin
            rx_done_pulse <= 1'b0; // Default pulse low

            case (rx_state)
                RX_IDLE: begin
                    rx_clk_cnt <= 16'd0;
                    rx_bit_idx <= 3'd0;
                    // Detect falling edge of Start bit
                    if (rx_sync2 == 1'b0) begin
                        rx_state <= RX_START;
                    end
                end

                RX_START: begin
                    // Sample at the midpoint of Start bit
                    if (rx_clk_cnt < (CLKS_PER_BIT / 2) - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1'b1;
                    end else begin
                        rx_clk_cnt <= 16'd0;
                        if (rx_sync2 == 1'b0) begin
                            // Valid start bit confirmed, proceed to data bits
                            rx_state <= RX_DATA;
                        end else begin
                            // False start bit / glitch, return to IDLE
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_DATA: begin
                    // Wait one full bit period to sample at midpoint of each data bit
                    if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1'b1;
                    end else begin
                        rx_clk_cnt          <= 16'd0;
                        FIFOrx[rx_bit_idx]  <= rx_sync2;
                        if (rx_bit_idx < 3'd7) begin
                            rx_bit_idx <= rx_bit_idx + 1'b1;
                        end else begin
                            rx_state   <= RX_STOP;
                        end
                    end
                end

                RX_STOP: begin
                    // Wait one full bit period to sample midpoint of Stop bit
                    if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                        rx_clk_cnt <= rx_clk_cnt + 1'b1;
                    end else begin
                        rx_clk_cnt <= 16'd0;
                        rx_state   <= RX_IDLE;
                        if (rx_sync2 == 1'b1) begin
                            // Valid Stop bit confirmed
                            r_rxdata      <= FIFOrx;
                            rx_done_pulse <= 1'b1;
                        end
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Register Writes & Software Control
    // -------------------------------------------------------------------------
    always @(posedge clk_i) begin
        if (rst_i) begin
            r_txdata   <= 8'd0;
            r_rxdone   <= 1'b0;
            r_transmit <= 1'b0;
        end else begin
            // TRANSMIT bit is cleared in the cycle following the write (Section 2.2.3)
            r_transmit <= 1'b0;

            // Software bus write operations
            if (we_i) begin
                case (reg_offset)
                    2'b00: begin
                        // Offset 0x00: TXDATA
                        r_txdata <= data_i[7:0];
                    end
                    2'b10: begin
                        // Offset 0x08: CONTROL
                        // Bit 0: TRANSMIT
                        if (data_i[0]) begin
                            r_transmit <= 1'b1;
                        end
                        // Bit 1: RXDONE - cleared by writing 0
                        if (!data_i[1]) begin
                            r_rxdone <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end

            // Hardware sets RXDONE upon completed reception
            if (rx_done_pulse) begin
                r_rxdone <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Bus Read Operations (Synchronous / Combinational Mux)
    // -------------------------------------------------------------------------
    always @(*) begin
        if (oe_i) begin
            case (reg_offset)
                2'b00:   data_o = {24'd0, r_txdata};
                2'b01:   data_o = {24'd0, r_rxdata};
                2'b10:   data_o = {29'd0, r_txdone, r_rxdone, 1'b0};
                default: data_o = 32'd0;
            endcase
        end else begin
            data_o = 32'd0;
        end
    end

endmodule