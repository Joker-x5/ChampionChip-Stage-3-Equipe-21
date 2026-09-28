

//  ---------- INLCUDED BLOCK: uart  ---------- 
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



//  ---------- INLCUDED BLOCK: Stage3_RISCV  ---------- 
module Stage3_RISCV (

  input wire clk_i,
  input wire rst_i,
  output wire [31:0] reg_wb_data,
  input wire [31:0] gpio,
  output wire gpio_oe_o,
  output wire uart_we_o,
  input wire [31:0] uart,
  output wire uart_oe_o,
  output wire gpio_we_o,
  output wire [31:0] address_o,
  output wire [31:0] data_o

);

//Internal Wires
 wire [31:0] w_1;
 wire [31:0] w_2;
 wire w_3;
 wire [31:0] w_4;
 wire w_5;
 wire [3:0] w_6;
 wire [1:0] w_7;
 wire [1:0] w_8;
 wire [31:0] w_9;
 wire [2:0] w_10;
 wire w_11;
 wire [31:0] w_12;
 wire w_13;
 wire [31:0] w_14;
 wire [31:0] w_15;
 wire [31:0] w_17;
 wire w_19;
 wire [3:0] w_20;
 wire w_21;
 wire [31:0] w_22;
 wire w_23;
 wire w_24;
 wire [31:0] w_27;
 wire [3:0] w_29;

//Interface Assigns
assign address_o[31:0] = w_1;
assign data_o[31:0] = w_17;

//Instances of Modules
firmware_memory blk3793_84 (
         .i_address (w_1),
         .o_instruction (w_2)
     );

datapath blkProj14918_86 (
         .clk (clk_i),
         .rst (rst_i),
         .reg_wb_data (reg_wb_data[31:0]),
         .pc_write (w_3),
         .instr_in (w_4),
         .reg_write (w_5),
         .alu_op (w_6),
         .alu_a_sel (w_7),
         .alu_b_sel (w_8),
         .mem_data_i (w_9),
         .wb_sel (w_10),
         .ir_write (w_11),
         .mem_address_o (w_12),
         .branch_taken (w_13),
         .rs2_data (w_14),
         .instr_out (w_15)
     );

RISCV_DMEM blk3033_87 (
         .i_Clk (clk_i),
         .i_Data (w_17),
         .i_Address (w_1),
         .i_We (w_19),
         .i_Byte_Write (w_20),
         .i_Output_Enable (w_21),
         .o_Data (w_22)
     );

control #(.FETCH(4'd0), .DECODE(4'd1), .EXEC_R(4'd2), .WRITE_BACK(4'd3), .EXEC_I(4'd4), .MEM_ADDR(4'd5), .MEM_READ(4'd6), .MEM_WRITE(4'd7), .EXEC_B(4'd8), .EXEC_J(4'd9), .EXEC_U(4'd10)) blk3036_88 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .PC_Write (w_3),
         .Reg_Write (w_5),
         .ALU_Op (w_6),
         .ALUSel_A (w_7),
         .ALUSel_B (w_8),
         .wb_sel (w_10),
         .IR_Write (w_11),
         .branch_taken (w_13),
         .Instruction (w_15),
         .oe_o (w_23),
         .we_o (w_24)
     );

RISCV_LSU blk3055_94 (
         .mem_data_o (w_17),
         .core_data_i (w_9),
         .core_address_o (w_12),
         .core_data_o (w_14),
         .instr (w_15),
         .is_store (w_24),
         .mem_data_i (w_4),
         .mem_address_i (w_27),
         .byte_write_i (w_29)
     );

Stage3Addr_Dec blk4627_95 (
         .gpio_data_i (gpio[31:0]),
         .gpio_oe_o (gpio_oe_o),
         .uart_we_o (uart_we_o),
         .uart_data_i (uart[31:0]),
         .uart_oe_o (uart_oe_o),
         .gpio_we_o (gpio_we_o),
         .address_o (w_1),
         .imem_data_i (w_2),
         .data_o (w_4),
         .dmem_we_o (w_19),
         .dmem_bw_o (w_20),
         .dmem_oe_o (w_21),
         .dmem_data_i (w_22),
         .oe_i (w_23),
         .we_i (w_24),
         .address_i (w_27),
         .bw_i (w_29)
     );


endmodule

//  ---------- INLCUDED BLOCK: RISCV_DMEM  ---------- 
`timescale 1ns / 1ps
module RISCV_DMEM (
    input  [31:0] i_Data,  
    input  [31:0] i_Address,  
    input         i_We,           // Write enable from address decoder
    input  [3:0]  i_Byte_Write,
    input         i_Output_Enable,
    input         i_Clk,       
    output reg [31:0] o_Data
);  
    reg [31:0] r_Contents [0:2047];
    wire [10:0] word_index = i_Address[12:2]; 
    
    always @(posedge i_Clk) begin
        if (i_We && i_Byte_Write[0]) r_Contents[word_index][7:0]   <= i_Data[7:0];
        if (i_We && i_Byte_Write[1]) r_Contents[word_index][15:8]  <= i_Data[15:8];
        if (i_We && i_Byte_Write[2]) r_Contents[word_index][23:16] <= i_Data[23:16];
        if (i_We && i_Byte_Write[3]) r_Contents[word_index][31:24] <= i_Data[31:24];

        if (i_Output_Enable) begin
            o_Data <= r_Contents[word_index];
        end else begin
            o_Data <= 32'h00000000;
        end
    end
endmodule



//  ---------- INLCUDED BLOCK: control  ---------- 
`timescale 1ns/1ps
module control (
    input wire clk_i,
    input wire rst_i,
    input wire [31:0] Instruction,
    input wire branch_taken,

    output reg PC_Write,
    output reg IR_Write,
    output reg oe_o,
    output reg we_o,
    output reg Reg_Write,
    output reg [3:0] ALU_Op,
    output reg [1:0] ALUSel_A,
    output reg [1:0] ALUSel_B,
    output reg [2:0] wb_sel, 
    output reg Branch 
);

    wire [6:0] opcode = Instruction[6:0];
    wire [2:0] funct3 = Instruction[14:12];
    wire [6:0] funct7 = Instruction[31:25];

    parameter FETCH      = 4'd0;
    parameter DECODE     = 4'd1;
    parameter EXEC_R     = 4'd2;
    parameter WRITE_BACK = 4'd3;
    parameter EXEC_I     = 4'd4;
    parameter MEM_ADDR   = 4'd5;
    parameter MEM_READ   = 4'd6;
    parameter MEM_WRITE  = 4'd7;
    parameter EXEC_B     = 4'd8;
    parameter EXEC_J     = 4'd9;
    parameter EXEC_U     = 4'd10;
    
    reg [3:0] current_state, next_state;

    always @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            current_state <= FETCH;
        else
            current_state <= next_state;
    end

    always @(*) begin
        case (current_state)
            FETCH: next_state = DECODE;
            DECODE: begin
                case (opcode)
                    7'b0110011: next_state = EXEC_R;   
                    7'b0010011: next_state = EXEC_I;   
                    7'b0000011: next_state = MEM_ADDR; 
                    7'b0100011: next_state = MEM_ADDR; 
                    7'b1100011: next_state = EXEC_B;   
                    7'b1101111: next_state = EXEC_J;   
                    7'b1100111: next_state = EXEC_J;   
                    7'b0110111: next_state = EXEC_U;   
                    7'b0010111: next_state = EXEC_U; 
                    7'b0001111: next_state = FETCH;    // [NEW] FENCE: memory ordering barrier (in-order single-core NOP)
                    7'b1110011: next_state = FETCH;    // [NEW] SYSTEM: ECALL (funct12=0), EBREAK (funct12=1) bare-metal NOP
                    default:    next_state = FETCH;    
                endcase
            end
          
            EXEC_R: next_state = WRITE_BACK; 
            EXEC_I: next_state = WRITE_BACK;
            EXEC_B: next_state = FETCH;  
            EXEC_J: next_state = WRITE_BACK;  
            EXEC_U: next_state = WRITE_BACK; 
          
            MEM_ADDR: begin
                if (opcode == 7'b0000011)
                    next_state = MEM_READ;  
                else if (opcode == 7'b0100011)
                    next_state = MEM_WRITE; 
                else
                    next_state = FETCH;     
            end
            
            MEM_READ:  next_state = WRITE_BACK; 
            MEM_WRITE: next_state = FETCH;  
          
            WRITE_BACK: next_state = FETCH;  
            default: next_state = FETCH;
        endcase
    end

    always @(*) begin
        PC_Write = 1'b0; IR_Write = 1'b0; oe_o = 1'b0; we_o = 1'b0;
        Reg_Write = 1'b0; ALU_Op = 4'h0; 
        ALUSel_A = 2'b00; ALUSel_B = 2'b00; 
        wb_sel = 3'b000; Branch = 1'b0; 

        case (current_state)
            FETCH: begin
                oe_o = 1'b1;
                IR_Write = 1'b1;
                PC_Write = 1'b1;
                ALUSel_A = 2'b01; 
                ALUSel_B = 2'b10; 
                ALU_Op = 4'h1;
            end
          
          DECODE: begin
                // <--- [ADD HERE] Intentionally empty: all signals remain at default 0
            end
            
            EXEC_R: begin
                ALUSel_A = 2'b00; 
                ALUSel_B = 2'b00; 
                Reg_Write = 1'b0;

                if (funct7 == 7'b0000001) begin
                    wb_sel = 3'b001; 
                end else if (funct7 == 7'b1000000) begin
                    wb_sel = 3'b010; 
                end else begin
                    wb_sel = 3'b000;
                    case (funct3)
                        3'b000: ALU_Op = (funct7[5]) ? 4'h2 : 4'h1; 
                        3'b001: ALU_Op = 4'h6;                      
                        3'b010: ALU_Op = 4'h9;                      
                        3'b011: ALU_Op = 4'hA;                      
                        3'b100: ALU_Op = 4'h5;                      
                        3'b101: ALU_Op = (funct7[5]) ? 4'h8 : 4'h7; 
                        3'b110: ALU_Op = 4'h4;                      
                        3'b111: ALU_Op = 4'h3;                      
                        default: ALU_Op = 4'h0;
                    endcase
                end
            end
            
            EXEC_I: begin
                ALUSel_A = 2'b00; 
                ALUSel_B = 2'b01; 
                Reg_Write = 1'b0;
                wb_sel = 3'b000;
                
                case (funct3)
                    3'b000: ALU_Op = 4'h1; 
                    3'b001: ALU_Op = 4'h6; 
                    3'b010: ALU_Op = 4'h9; 
                    3'b011: ALU_Op = 4'hA; 
                    3'b100: ALU_Op = 4'h5; 
                    3'b101: ALU_Op = (funct7[5]) ? 4'h8 : 4'h7; 
                    3'b110: ALU_Op = 4'h4; 
                    3'b111: ALU_Op = 4'h3; 
                    default: ALU_Op = 4'h0;
                endcase
            end
          
            MEM_ADDR: begin
                ALUSel_A = 2'b00; 
                ALUSel_B = 2'b01; 
                ALU_Op = 4'h1;    
            end
          
            MEM_WRITE: begin
                we_o = 1'b1;
                ALUSel_A = 2'b00;
                ALUSel_B = 2'b01;
                ALU_Op = 4'h1;
            end
          
            MEM_READ: begin
                oe_o = 1'b1;
                ALUSel_A = 2'b00;
                ALUSel_B = 2'b01;
                ALU_Op = 4'h1;
            end
                  
            EXEC_B: begin
                ALUSel_A = 2'b11; 
                ALUSel_B = 2'b01; 
                ALU_Op = 4'h1;    
                Branch = 1'b1;
                if (branch_taken) PC_Write = 1'b1;
            end
          
            EXEC_J: begin 
                ALU_Op = 4'h1;
                ALUSel_B = 2'b01; 

                if (opcode == 7'b1101111) begin // JAL 
                    ALUSel_A = 2'b11; 
                end else begin                  // JALR 
                    ALUSel_A = 2'b00; 
                end 

                
                Reg_Write = 1'b0; 
                wb_sel = 3'b100;  
            end 
          EXEC_U: begin
                ALU_Op = 4'h1; 
                ALUSel_B = 2'b01; 
                Reg_Write = 1'b0;
                wb_sel = 3'b000;

                if (opcode == 7'b0010111) begin // AUIPC
                    ALUSel_A = 2'b11; 
                end else begin                  // LUI
                    ALUSel_A = 2'b10; 
                end
            end
          
            WRITE_BACK: begin
              Reg_Write = 1'b1; 
              case (opcode)
                  7'b0110011: begin // R-type
                      ALUSel_A = 2'b00;
                      ALUSel_B = 2'b00;
                      if (funct7 == 7'b0000001) begin
                          wb_sel = 3'b001; 
                      end else if (funct7 == 7'b1000000) begin
                          wb_sel = 3'b010; 
                      end else begin
                          wb_sel = 3'b000;
                          case (funct3)
                              3'b000: ALU_Op = (funct7[5]) ? 4'h2 : 4'h1; 
                              3'b001: ALU_Op = 4'h6;                      
                              3'b010: ALU_Op = 4'h9;                      
                              3'b011: ALU_Op = 4'hA;                      
                              3'b100: ALU_Op = 4'h5;                      
                              3'b101: ALU_Op = (funct7[5]) ? 4'h8 : 4'h7; 
                              3'b110: ALU_Op = 4'h4;                      
                              3'b111: ALU_Op = 4'h3;                      
                              default: ALU_Op = 4'h0;
                          endcase
                      end
                  end
                  7'b0010011: begin // I-type
                      ALUSel_A = 2'b00; 
                      ALUSel_B = 2'b01; 
                      wb_sel = 3'b000;
                      case (funct3)
                          3'b000: ALU_Op = 4'h1; 
                          3'b001: ALU_Op = 4'h6; 
                          3'b010: ALU_Op = 4'h9; 
                          3'b011: ALU_Op = 4'hA; 
                          3'b100: ALU_Op = 4'h5; 
                          3'b101: ALU_Op = (funct7[5]) ? 4'h8 : 4'h7; 
                          3'b110: ALU_Op = 4'h4; 
                          3'b111: ALU_Op = 4'h3; 
                          default: ALU_Op = 4'h0;
                      endcase
                  end
                  7'b0000011: begin // Load
                      wb_sel = 3'b011; 
                      oe_o = 1'b1;     // Sustain memory stability during latch
                  end
                  7'b1101111: begin // JAL
                    ALUSel_A = 2'b11; 
                    ALUSel_B = 2'b01; 
                    ALU_Op = 4'h1;
                    wb_sel = 3'b100;
                    PC_Write = 1'b1;
                end
                7'b1100111: begin // JALR
                    ALUSel_A = 2'b00; 
                    ALUSel_B = 2'b01; 
                    ALU_Op = 4'h1;
                    wb_sel = 3'b100;
                    PC_Write = 1'b1;
                end
                  7'b0110111: begin // LUI
                      ALUSel_A = 2'b10;
                      ALUSel_B = 2'b01;
                      ALU_Op = 4'h1;
                      wb_sel = 3'b000;
                  end
                  7'b0010111: begin // AUIPC
                      ALUSel_A = 2'b11;
                      ALUSel_B = 2'b01;
                      ALU_Op = 4'h1;
                      wb_sel = 3'b000;
                  end
                  default: wb_sel = 3'b000;
              endcase
          end
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: RISCV_LSU  ---------- 
`timescale 1ns / 1ps
// =============================================================================
// Module: RISCV_LSU (Load/Store Unit)
// =============================================================================
// Handles byte, halfword, and word memory access alignment, byte-enable mask
// generation for stores, sign/zero extension for loads, and downstream 4-byte
// word address alignment.
//
// Internal Decoding:
// Takes the 32-bit instruction directly via `instr` and extracts `funct3`
// (instr[14:12]) internally without requiring any external slicing adapters.
//
// RISC-V funct3 Encodings:
//   3'b000 : LB  (Load Byte, signed)       / SB (Store Byte)
//   3'b001 : LH  (Load Halfword, signed)   / SH (Store Halfword)
//   3'b010 : LW  (Load Word)               / SW (Store Word)
//   3'b100 : LBU (Load Byte, unsigned)
//   3'b101 : LHU (Load Halfword, unsigned)
// =============================================================================

module RISCV_LSU (
    input  wire [31:0] core_data_o,    // Store data from RF (rs2)
    input  wire [31:0] core_address_o, // Target byte address from ALU/datapath
    input  wire [31:0] instr,          // 32-bit instruction from IR
    input  wire        is_store,       // Store enable (active during MEM_WRITE)
    output reg  [31:0] core_data_i,    // Formatted load data to datapath/WB mux
    input  wire [31:0] mem_data_i,     // 32-bit raw word read from memory
    output wire [31:0] mem_address_i,  // 4-byte word-aligned address to AddressDecoder/Memory
    output reg  [31:0] mem_data_o,     // Byte-lane shifted store data to DMEM
    output reg  [3:0]  byte_write_i    // 4-bit byte-write enable mask to DMEM
);

    // Operation Size Encodings (matching standard RISC-V funct3)
    localparam SIZE_B  = 3'b000,
               SIZE_H  = 3'b001,
               SIZE_W  = 3'b010,
               SIZE_BU = 3'b100,
               SIZE_HU = 3'b101;

    // Internal instruction slicing: extract funct3 field
    wire [2:0] op_size = instr[14:12];

    // Byte offset within the 4-byte word (lower 2 address bits)
    wire [1:0] offset = core_address_o[1:0];

    // Downstream memory address is 4-byte word-aligned
    assign mem_address_i = {core_address_o[31:2], 2'b00};

    // -------------------------------------------------------------------------
    // Store Operation Logic (Core -> Memory)
    // -------------------------------------------------------------------------
    always @(*) begin
        // Default assignments to prevent unintended latch inference
        byte_write_i = 4'b0000;
        mem_data_o   = 32'h00000000;

        if (is_store) begin
            mem_data_o = core_data_o << (offset * 8);
            case (op_size)
                SIZE_B:  byte_write_i = 4'b0001 << offset;
                SIZE_H:  byte_write_i = 4'b0011 << offset;
                SIZE_W:  byte_write_i = 4'b1111;
                default: byte_write_i = 4'b0000;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Load Operation Logic (Memory -> Core)
    // -------------------------------------------------------------------------
    // Align memory data down to byte 0 before sign/zero extension
    wire [31:0] aligned_load_data = mem_data_i >> (offset * 8);

    always @(*) begin
        // Default assignment before case tree to guarantee latch-free combinational logic
        core_data_i = 32'h00000000;

        case (op_size)
            SIZE_B:  core_data_i = {{24{aligned_load_data[7]}},  aligned_load_data[7:0]};   
            SIZE_H:  core_data_i = {{16{aligned_load_data[15]}}, aligned_load_data[15:0]}; 
            SIZE_W:  core_data_i = aligned_load_data;                                     
            SIZE_BU: core_data_i = {24'b0,                       aligned_load_data[7:0]};   
            SIZE_HU: core_data_i = {16'b0,                       aligned_load_data[15:0]};  
            default: core_data_i = 32'h00000000;
        endcase
    end

endmodule



//  ---------- INLCUDED BLOCK: firmware_memory  ---------- 
`timescale 1ns/1ps

module firmware_memory (
    input  wire [31:0] i_address,
    output reg  [31:0] o_instruction
);

always @(*) begin
    case (i_address)
        32'h00400000: o_instruction = 32'hF1000437; // lui  s0, 0xF1000
        32'h00400004: o_instruction = 32'hF00004B7; // lui  s1, 0xF0000
        32'h00400008: o_instruction = 32'h0FE00293; // addi t0, zero, 254
        32'h0040000C: o_instruction = 32'h0054A423; // sw   t0, 8(s1)
        32'h00400010: o_instruction = 32'h0004A023; // sw   zero, 0(s1)
        32'h00400014: o_instruction = 32'h0044A283; // lw   t0, 4(s1)
        32'h00400018: o_instruction = 32'h0012F293; // andi t0, t0, 1
        32'h0040001C: o_instruction = 32'hFE028CE3; // beq  t0, zero, wait_trigger
        32'h00400020: o_instruction = 32'h00842283; // lw   t0, 8(s0)
        32'h00400024: o_instruction = 32'h0022F293; // andi t0, t0, 2
        32'h00400028: o_instruction = 32'hFE028CE3; // beq  t0, zero, read_co
        32'h0040002C: o_instruction = 32'h00042423; // sw   zero, 8(s0)
        32'h00400030: o_instruction = 32'h00442903; // lw   s2, 4(s0)
        32'h00400034: o_instruction = 32'h00842283; // lw   t0, 8(s0)
        32'h00400038: o_instruction = 32'h0022F293; // andi t0, t0, 2
        32'h0040003C: o_instruction = 32'hFE028CE3; // beq  t0, zero, read_h2
        32'h00400040: o_instruction = 32'h00042423; // sw   zero, 8(s0)
        32'h00400044: o_instruction = 32'h00442983; // lw   s3, 4(s0)
        32'h00400048: o_instruction = 32'h00842283; // lw   t0, 8(s0)
        32'h0040004C: o_instruction = 32'h0022F293; // andi t0, t0, 2
        32'h00400050: o_instruction = 32'hFE028CE3; // beq  t0, zero, read_temp
        32'h00400054: o_instruction = 32'h00042423; // sw   zero, 8(s0)
        32'h00400058: o_instruction = 32'h00442A03; // lw   s4, 4(s0)
        32'h0040005C: o_instruction = 32'h00842283; // lw   t0, 8(s0)
        32'h00400060: o_instruction = 32'h0022F293; // andi t0, t0, 2
        32'h00400064: o_instruction = 32'hFE028CE3; // beq  t0, zero, read_hum
        32'h00400068: o_instruction = 32'h00042423; // sw   zero, 8(s0)
        32'h0040006C: o_instruction = 32'h00442A83; // lw   s5, 4(s0)
        32'h00400070: o_instruction = 32'h001A9293; // slli t0, s5, 1
        32'h00400074: o_instruction = 32'h412282B3; // sub  t0, t0, s2
        32'h00400078: o_instruction = 32'h413282B3; // sub  t0, t0, s3
        32'h0040007C: o_instruction = 32'h414282B3; // sub  t0, t0, s4
        32'h00400080: o_instruction = 32'h0002D463; // bgez t0, z0_pos
        32'h00400084: o_instruction = 32'h00000293; // addi t0, zero, 0
        32'h00400088: o_instruction = 32'h00028B13; // addi s6, t0, 0
        32'h0040008C: o_instruction = 32'h00300313; // addi t1, zero, 3
        32'h00400090: o_instruction = 32'h026902B3; // mul  t0, s2, t1
        32'h00400094: o_instruction = 32'h00400313; // addi t1, zero, 4
        32'h00400098: o_instruction = 32'h026983B3; // mul  t2, s3, t1
        32'h0040009C: o_instruction = 32'h007282B3; // add  t0, t0, t2
        32'h004000A0: o_instruction = 32'h014282B3; // add  t0, t0, s4
        32'h004000A4: o_instruction = 32'h001A9313; // slli t1, s5, 1
        32'h004000A8: o_instruction = 32'h406282B3; // sub  t0, t0, t1
        32'h004000AC: o_instruction = 32'hF8828293; // addi t0, t0, -120
        32'h004000B0: o_instruction = 32'h0002D463; // bgez t0, z1_pos
        32'h004000B4: o_instruction = 32'h00000293; // addi t0, zero, 0
        32'h004000B8: o_instruction = 32'h00028B93; // addi s7, t0, 0
        32'h004000BC: o_instruction = 32'h00191293; // slli t0, s2, 1
        32'h004000C0: o_instruction = 32'h00300313; // addi t1, zero, 3
        32'h004000C4: o_instruction = 32'h026A03B3; // mul  t2, s4, t1
        32'h004000C8: o_instruction = 32'h007282B3; // add  t0, t0, t2
        32'h004000CC: o_instruction = 32'h002A9313; // slli t1, s5, 2
        32'h004000D0: o_instruction = 32'h406282B3; // sub  t0, t0, t1
        32'h004000D4: o_instruction = 32'hF3828293; // addi t0, t0, -200
        32'h004000D8: o_instruction = 32'h0002D463; // bgez t0, z2_pos
        32'h004000DC: o_instruction = 32'h00000293; // addi t0, zero, 0
        32'h004000E0: o_instruction = 32'h00028C13; // addi s8, t0, 0
        32'h004000E4: o_instruction = 32'h03804063; // bgtz s8, is_fire
        32'h004000E8: o_instruction = 32'h017B4863; // blt  s6, s7, is_smold
        32'h004000EC: o_instruction = 32'h00000513; // addi a0, zero, 0
        32'h004000F0: o_instruction = 32'h00000593; // addi a1, zero, 0
        32'h004000F4: o_instruction = 32'h0180006F; // jal  zero, send_out
        32'h004000F8: o_instruction = 32'h00100513; // addi a0, zero, 1
        32'h004000FC: o_instruction = 32'h00200593; // addi a1, zero, 2
        32'h00400100: o_instruction = 32'h00C0006F; // jal  zero, send_out
        32'h00400104: o_instruction = 32'h00200513; // addi a0, zero, 2
        32'h00400108: o_instruction = 32'h00600593; // addi a1, zero, 6
        32'h0040010C: o_instruction = 32'h00B4A023; // sw   a1, 0(s1)
        32'h00400110: o_instruction = 32'h00A42023; // sw   a0, 0(s0)
        32'h00400114: o_instruction = 32'h00842283; // lw   t0, 8(s0)
        32'h00400118: o_instruction = 32'h0042F293; // andi t0, t0, 4
        32'h0040011C: o_instruction = 32'hFE028CE3; // beq  t0, zero, wait_tx
        32'h00400120: o_instruction = 32'h0044A283; // lw   t0, 4(s1)
        32'h00400124: o_instruction = 32'h0012F293; // andi t0, t0, 1
        32'h00400128: o_instruction = 32'hFE029CE3; // bne  t0, zero, wait_release
        32'h0040012C: o_instruction = 32'hEE9FF06F; // jal  zero, wait_trigger

        default: o_instruction = 32'h00000013; // NOP
    endcase
end
endmodule



//  ---------- INLCUDED BLOCK: imm_gen  ---------- 
`timescale 1ns/1ps
module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    wire [6:0] opcode = instr[6:0];

    localparam OP_IMM    = 7'b0010011, OP_LOAD   = 7'b0000011,
               OP_JALR   = 7'b1100111, OP_SYSTEM = 7'b1110011,
               OP_STORE  = 7'b0100011, OP_BRANCH = 7'b1100011,
               OP_LUI    = 7'b0110111, OP_AUIPC  = 7'b0010111,
               OP_JAL    = 7'b1101111;

    always @(*) begin
        case (opcode)
            OP_IMM, OP_LOAD, OP_JALR, OP_SYSTEM:
                imm = {{20{instr[31]}}, instr[31:20]};
            OP_STORE:
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            OP_BRANCH:
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            OP_LUI, OP_AUIPC:
                imm = {instr[31:12], 12'b0};
            OP_JAL:
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'd0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: regfile  ---------- 
`timescale 1ns/1ps
module regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [31:0] instr,
    
    
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    reg [31:0] regs [1:31];
    wire [4:0] rs1_addr = instr[19:15];
    wire [4:0] rs2_addr = instr[24:20];
    wire [4:0] rd_addr  = instr[11:7];
    integer i;

    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 1; i <= 31; i = i + 1)
                regs[i] <= 32'd0;
        end else if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end
endmodule



//  ---------- INLCUDED BLOCK: pc_reg  ---------- 
`timescale 1ns/1ps
module pc_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        pc_write,
    input  wire [31:0] pc_next,
    output reg  [31:0] pc
);
    localparam [31:0] IMEM_BASE = 32'h00400000;

    always @(posedge clk) begin
        if (rst)
            pc <= IMEM_BASE;
        else if (pc_write)
            pc <= {pc_next[31:1], 1'b0}; 
    end
endmodule



//  ---------- INLCUDED BLOCK: alu  ---------- 
`timescale 1ns/1ps
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result
);
    localparam ALU_PASS_B = 4'h0, ALU_ADD = 4'h1, ALU_SUB = 4'h2,
               ALU_AND = 4'h3, ALU_OR = 4'h4, ALU_XOR = 4'h5,
               ALU_SLL = 4'h6, ALU_SRL = 4'h7, ALU_MRS = 4'h8,
               ALU_SLT = 4'h9, ALU_SLTU = 4'hA;

    always @(*) begin
        case (alu_op)
            ALU_PASS_B: result = b;
            ALU_ADD:    result = a + b;
            ALU_SUB:    result = a - b;
            ALU_AND:    result = a & b;
            ALU_OR:     result = a | b;
            ALU_XOR:    result = a ^ b;
            ALU_SLL:    result = a << b[4:0];
            ALU_SRL:    result = a >> b[4:0];
            ALU_MRS:    result = $signed(a) >>> b[4:0];
            ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (a < b) ? 32'd1 : 32'd0;
            default:    result = 32'd0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: ir_reg  ---------- 
`timescale 1ns/1ps
module ir_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        ir_write,
    input  wire [31:0] instr_in,
    output reg  [31:0] instr_out
);
    always @(posedge clk) begin
        if (rst)
            instr_out <= 32'd0;
        else if (ir_write)
            instr_out <= instr_in;
    end
endmodule



//  ---------- INLCUDED BLOCK: mult_unit  ---------- 
`timescale 1ns/1ps
module mult_unit (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] instr,
    output reg  [31:0] result
);
    localparam MUL = 4'h0, MULH = 4'h1, MULHSU = 4'h2, MULHU = 4'h3;

    wire signed [63:0] a_signed_ext   = {{32{a[31]}}, a};
    wire signed [63:0] b_signed_ext   = {{32{b[31]}}, b};
    wire signed [63:0] a_unsigned_ext = {32'b0, a};
    wire signed [63:0] b_unsigned_ext = {32'b0, b};

    reg signed [63:0] product;

    wire [3:0] mult_op = {1'b0, instr[14:12]};
    always @(*) begin
        case (mult_op)
            MUL: begin
                product = a_signed_ext * b_signed_ext;
                result  = product[31:0];
            end
            MULH: begin
                product = a_signed_ext * b_signed_ext;
                result  = product[63:32];
            end
            MULHSU: begin
                product = a_signed_ext * b_unsigned_ext;
                result  = product[63:32];
            end
            MULHU: begin
                product = a_unsigned_ext * b_unsigned_ext;
                result  = product[63:32];
            end
            default: begin
                product = 64'sd0;
                result  = 32'd0;
            end
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: branch_comp  ---------- 
`timescale 1ns/1ps
module branch_comp (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [31:0] instr,
    output reg         branch_taken
);
    wire [2:0] funct3 = instr[14:12];
    localparam F3_BEQ = 3'b000, F3_BNE = 3'b001, F3_BLT = 3'b100,
               F3_BGE = 3'b101, F3_BLTU = 3'b110, F3_BGEU = 3'b111;

    always @(*) begin
        case (funct3)
            F3_BEQ:  branch_taken = (rs1_data == rs2_data);
            F3_BNE:  branch_taken = (rs1_data != rs2_data);
            F3_BLT:  branch_taken = ($signed(rs1_data) <  $signed(rs2_data));
            F3_BGE:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
            F3_BLTU: branch_taken = (rs1_data <  rs2_data);
            F3_BGEU: branch_taken = (rs1_data >= rs2_data);
            default: branch_taken = 1'b0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: crc_unit  ---------- 
`timescale 1ns/1ps
module crc_unit (
    input  wire [31:0] data_in,  // Port 1: rs1
    input  wire [31:0] seed,     // Port 2: rs2
    input  wire [31:0] instr,    // Port 3: Instruction bus
    output reg  [31:0] result    // Output
);
    localparam [15:0] POLY16 = 16'h1021;
    localparam CRCB = 3'b000, CRCH = 3'b001, CRCW = 3'b010;

    // Internal bit-slicing
    wire [2:0] funct3 = instr[14:12];

    // Internal calculation variables (NO external input ports)
    integer i;
    reg [15:0] crc;
    reg        msb;

    always @(*) begin
        crc = seed[15:0];
        case (funct3)
            CRCB: begin // 8-bit CRC
                for (i = 7; i >= 0; i = i - 1) begin
                    msb = crc[15] ^ data_in[i];
                    crc = crc << 1;
                    if (msb) crc = crc ^ POLY16;
                end
                result = {16'd0, crc};
            end

            CRCH: begin // 16-bit CRC
                for (i = 15; i >= 0; i = i - 1) begin
                    msb = crc[15] ^ data_in[i];
                    crc = crc << 1;
                    if (msb) crc = crc ^ POLY16;
                end
                result = {16'd0, crc};
            end

            CRCW: begin // 32-bit CRC
                for (i = 31; i >= 0; i = i - 1) begin
                    msb = crc[15] ^ data_in[i];
                    crc = crc << 1;
                    if (msb) crc = crc ^ POLY16;
                end
                result = {16'd0, crc};
            end

            default: begin
                result = 32'd0;
            end
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: alu_a_mux  ---------- 
`timescale 1ns/1ps
module alu_a_mux (
    input  wire [1:0]  alu_a_sel,  // 00: RS1, 01: PC, 10: 0 (LUI), 11: pc_old (AUIPC/Branch)
    input  wire [31:0] rs1_data,
    input  wire [31:0] pc_out,
    input  wire [31:0] pc_old,
    output reg  [31:0] alu_a
);
    always @(*) begin
        case (alu_a_sel)
            2'b00:   alu_a = rs1_data;
            2'b01:   alu_a = pc_out;
            2'b10:   alu_a = 32'd0;
            2'b11:   alu_a = pc_old;
            default: alu_a = 32'd0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: alu_b_mux  ---------- 
`timescale 1ns/1ps
module alu_b_mux (
    input  wire [1:0]  alu_b_sel,  // 00: RS2, 01: Immediate, 10: +4 (PC+4)
    input  wire [31:0] rs2_data,
    input  wire [31:0] imm_out,
    output reg  [31:0] alu_b
);
    always @(*) begin
        case (alu_b_sel)
            2'b00:   alu_b = rs2_data;
            2'b01:   alu_b = imm_out;
            2'b10:   alu_b = 32'd4;
            default: alu_b = 32'd0;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: wb_mux  ---------- 
`timescale 1ns/1ps
module wb_mux (
    input  wire [2:0]  wb_sel,       // 000: ALU, 001: Mult, 010: CRC, 011: Mem, 100: PC+4
    input  wire [31:0] alu_result,
    input  wire [31:0] mult_result,
    input  wire [31:0] crc_result,
    input  wire [31:0] mem_data_i,
    input  wire [31:0] pc_out,
    output reg  [31:0] reg_wb_data
);
    always @(*) begin
        case (wb_sel)
            3'b000:  reg_wb_data = alu_result;
            3'b001:  reg_wb_data = mult_result;
            3'b010:  reg_wb_data = crc_result;
            3'b011:  reg_wb_data = mem_data_i;
            3'b100:  reg_wb_data = pc_out;
            default: reg_wb_data = alu_result;
        endcase
    end
endmodule



//  ---------- INLCUDED BLOCK: pc_old_reg  ---------- 
`timescale 1ns/1ps
module pc_old_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        ir_write,
    input  wire [31:0] pc_out,
    output reg  [31:0] pc_old
);
    always @(posedge clk) begin
        if (rst)          pc_old <= 32'd0;
        else if (ir_write) pc_old <= pc_out;
    end
endmodule



//  ---------- INLCUDED BLOCK: mem_addr_mux  ---------- 
`timescale 1ns/1ps
module mem_addr_mux (
    input  wire        ir_write,     // 1: Fetch (pc_out), 0: Load/Store (alu_out_reg)
    input  wire [31:0] pc_out,
    input  wire [31:0] alu_out_reg,
    output wire [31:0] mem_address_o
);
    assign mem_address_o = (ir_write) ? pc_out : alu_out_reg;
endmodule



//  ---------- INLCUDED BLOCK: alu_out_reg  ---------- 
`timescale 1ns/1ps
module alu_out_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] alu_result,
    output reg  [31:0] alu_out_reg
);
    always @(posedge clk) begin
        if (rst) alu_out_reg <= 32'd0;
        else     alu_out_reg <= alu_result;
    end
endmodule



//  ---------- INLCUDED BLOCK: Stage3Addr_Dec  ---------- 
`timescale 1ns / 1ps
// =============================================================================
// ChampionChip Stage 3 - Enhanced Address Decoder (Stage3Addr_Dec)
// =============================================================================
// Description:
//   Memory and Peripheral Address Decoder for ChampionChip Phase 3.
//   Decodes CPU physical memory addresses into dedicated Chip Enable, Write Enable,
//   and Output Enable strobes for IMEM, DMEM, GPIO, and UART.
//   Multiplexes read data from all storage and peripheral blocks back to the core.
//
// Memory Map:
//   - IMEM (Instruction ROM) : 0x00400000 - 0x007FFFFC (4 MB, read-only)
//   - DMEM (Data RAM)        : 0x10010000 - 0x10011FFC (8 KB, read/write with byte mask)
//   - GPIO (Pin Controller)  : 0xF0000000 - 0xF0000008 (Word-aligned RW MMIO)
//   - UART (Serial Comm)     : 0xF1000000 - 0xF1000008 (Word-aligned RW MMIO)
// =============================================================================

module Stage3Addr_Dec (
    // Core Memory Access Bus
    input  wire [31:0] address_i,    // Effective byte address from Core / LSU
    input  wire        we_i,         // Global Write Enable strobe from Control Unit
    input  wire        oe_i,         // Global Output/Read Enable strobe from Control Unit
    input  wire [3:0]  bw_i,         // Byte-Write mask from LSU

    // Instruction Memory Interface (IMEM)
    input  wire [31:0] imem_data_i,  // Instruction word from IMEM
    output wire        imem_oe_o,    // Read strobe to IMEM

    // Data Memory Interface (DMEM)
    input  wire [31:0] dmem_data_i,  // Read data word from DMEM
    output wire        dmem_oe_o,    // Read strobe to DMEM
    output wire        dmem_we_o,    // Write strobe to DMEM
    output wire [3:0]  dmem_bw_o,    // 4-bit byte-enable mask to DMEM

    // Stage 3 GPIO Peripheral Interface (Base: 0xF0000000)
    input  wire [31:0] gpio_data_i,  // Read data word from GPIO (DATAOUT, DATAIN, DATADIR)
    output wire        gpio_oe_o,    // Read strobe to GPIO
    output wire        gpio_we_o,    // Write strobe to GPIO

    // Stage 3 UART Peripheral Interface (Base: 0xF1000000)
    input  wire [31:0] uart_data_i,  // Read data word from UART (TXDATA, RXDATA, CONTROL)
    output wire        uart_oe_o,    // Read strobe to UART
    output wire        uart_we_o,    // Write strobe to UART

    // Common Word-Aligned Address Output to all Memories/Peripherals
    output wire [31:0] address_o,    // Word-aligned address (bottom 2 bits cleared)

    // Multiplexed Read Data to Core / LSU
    output reg  [31:0] data_o        // Selected read data returned to Core
);

    // -------------------------------------------------------------------------
    // Address Region Decoding
    // -------------------------------------------------------------------------
    // IMEM: Base 0x00400000 (address[31:22] == 10'h001)
    wire is_imem = (address_i[31:22] == 10'h001);

    // DMEM: Base 0x10010000 (address[31:13] == 19'h08008)
    wire is_dmem = (address_i[31:13] == 19'h08008);

    // GPIO: Base 0xF0000000 (address[31:24] == 8'hF0)
    wire is_gpio = (address_i[31:24] == 8'hF0);

    // UART: Base 0xF1000000 (address[31:24] == 8'hF1)
    wire is_uart = (address_i[31:24] == 8'hF1);

    // -------------------------------------------------------------------------
    // Address Word-Alignment
    // -------------------------------------------------------------------------
    // Clear the two lower bits so all downstream blocks receive word-aligned addresses
    assign address_o = {address_i[31:2], 2'b00};

    // -------------------------------------------------------------------------
    // Gated Control Strobes
    // -------------------------------------------------------------------------
    // IMEM is read-only: we is never asserted for IMEM
    assign imem_oe_o = oe_i & is_imem;

    // DMEM read/write strobes and byte-mask
    assign dmem_oe_o = oe_i & is_dmem;
    assign dmem_we_o = we_i & is_dmem;
    assign dmem_bw_o = is_dmem ? bw_i : 4'b0000;

    // GPIO read/write strobes
    assign gpio_oe_o = oe_i & is_gpio;
    assign gpio_we_o = we_i & is_gpio;

    // UART read/write strobes
    assign uart_oe_o = oe_i & is_uart;
    assign uart_we_o = we_i & is_uart;

    // -------------------------------------------------------------------------
    // Read Data Multiplexer (Core Return Path)
    // -------------------------------------------------------------------------
    always @(*) begin
        if (is_imem) begin
            data_o = imem_data_i;
        end else if (is_dmem) begin
            data_o = dmem_data_i;
        end else if (is_gpio) begin
            data_o = gpio_data_i;
        end else if (is_uart) begin
            data_o = uart_data_i;
        end else begin
            data_o = 32'h00000000; // Safe default for unmapped address spaces
        end
    end

endmodule



// ---------- INCLUDED IP: datapath ---------- 


// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.

module datapath (

  input wire pc_write,
  input wire [31:0] instr_in,
  input wire reg_write,
  input wire [3:0] alu_op,
  input wire clk,
  input wire [1:0] alu_a_sel,
  input wire [1:0] alu_b_sel,
  input wire [31:0] mem_data_i,
  input wire [2:0] wb_sel,
  output wire [31:0] reg_wb_data,
  input wire ir_write,
  output wire [31:0] mem_address_o,
  output wire branch_taken,
  input wire rst,
  output wire [31:0] rs2_data,
  output wire [31:0] instr_out

);

//Internal Wires
 wire [31:0] w_1;
 wire [31:0] w_2;
 wire [31:0] w_4;
 wire [31:0] w_5;
 wire [31:0] w_9;
 wire [31:0] w_17;
 wire [31:0] w_18;
 wire [31:0] w_22;
 wire [31:0] w_23;
 wire [31:0] w_34;
 wire [31:0] w_35;
 wire [31:0] w_36;
 wire [31:0] w_38;

//Interface Assigns
assign reg_wb_data[31:0] = w_4;
assign rs2_data[31:0] = w_9;
assign instr_out[31:0] = w_1;

//Instances of Modules
imm_gen blk3889_1 (
         .instr (w_1),
         .imm (w_2)
     );

regfile blk3890_2 (
         .we (reg_write),
         .clk (clk),
         .rst (rst),
         .rs2_data (w_9),
         .instr (w_1),
         .rd_data (w_4),
         .rs1_data (w_5)
     );

pc_reg blk3892_4 (
         .pc_write (pc_write),
         .clk (clk),
         .rst (rst),
         .pc_next (w_17),
         .pc (w_18)
     );

alu blk3893_5 (
         .alu_op (alu_op[3:0]),
         .result (w_17),
         .a (w_22),
         .b (w_23)
     );

ir_reg blk3894_6 (
         .instr_in (instr_in[31:0]),
         .clk (clk),
         .ir_write (ir_write),
         .rst (rst),
         .instr_out (w_1)
     );

mult_unit blk3895_7 (
         .a (w_5),
         .b (w_9),
         .instr (w_1),
         .result (w_34)
     );

branch_comp blk3896_8 (
         .branch_taken (branch_taken),
         .rs1_data (w_5),
         .rs2_data (w_9),
         .instr (w_1)
     );

crc_unit blk3905_28 (
         .data_in (w_5),
         .seed (w_9),
         .instr (w_1),
         .result (w_35)
     );

alu_a_mux blk3964_31 (
         .alu_a_sel (alu_a_sel[1:0]),
         .rs1_data (w_5),
         .pc_out (w_18),
         .alu_a (w_22),
         .pc_old (w_36)
     );

alu_b_mux blk3965_32 (
         .alu_b_sel (alu_b_sel[1:0]),
         .imm_out (w_2),
         .rs2_data (w_9),
         .alu_b (w_23)
     );

wb_mux blk3967_33 (
         .mem_data_i (mem_data_i[31:0]),
         .wb_sel (wb_sel[2:0]),
         .reg_wb_data (w_4),
         .pc_out (w_18),
         .alu_result (w_17),
         .mult_result (w_34),
         .crc_result (w_35)
     );

mem_addr_mux blk3969_35 (
         .ir_write (ir_write),
         .mem_address_o (mem_address_o[31:0]),
         .pc_out (w_18),
         .alu_out_reg (w_38)
     );

alu_out_reg blk3975_42 (
         .clk (clk),
         .rst (rst),
         .alu_result (w_17),
         .alu_out_reg (w_38)
     );

pc_old_reg blk3968_47 (
         .clk (clk),
         .ir_write (ir_write),
         .rst (rst),
         .pc_out (w_18),
         .pc_old (w_36)
     );


endmodule



// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.



//  ---------- INLCUDED BLOCK: gpio  ---------- 
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


// Automatically generated by ChipInventor Cloud EDA Tool - 3.15
// Careful: this file (hdl.v) will be automatically replaced
// when you ask tool to generate top Verilog code by clicking
// at BLOCKS button.

module top (

  input wire clk_i,
  input wire rst_i,
  input wire rx_i,
  output wire tx_o,
  inout wire [7:0] pins_io

);

//Internal Wires
 wire [31:0] w_1;
 wire [31:0] w_2;
 wire w_3;
 wire w_4;
 wire [31:0] w_5;
 wire [31:0] w_6;
 wire w_7;
 wire w_8;
 wire [7:0] w_11;
 wire [7:0] w_12;

//Interface Assigns
 genvar gi;
 generate
     for (gi = 0; gi < 8; gi = gi + 1) begin : gen_pins_io
         assign pins_io[gi] = w_12[gi] ? w_11[gi] : 1'bz;
     end
 endgenerate

//Instances of Modules
uart #(.CLK_FREQ(50_000_000), .BAUD_RATE(115200), .AUTO_TX_ON_WRITE(1)) blk4650_3 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .rx_i (rx_i),
         .tx_o (tx_o),
         .addr_i (w_1),
         .data_i (w_2),
         .we_i (w_3),
         .oe_i (w_4),
         .data_o (w_5)
     );

Stage3_RISCV blk4658_9 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .address_o (w_1),
         .data_o (w_2),
         .uart_we_o (w_3),
         .uart_oe_o (w_4),
         .uart (w_5),
         .gpio (w_6),
         .gpio_oe_o (w_7),
         .gpio_we_o (w_8)
     );

gpio blk4659_18 (
         .clk_i (clk_i),
         .rst_i (rst_i),
         .datain (pins_io[7:0]),
         .data_o (w_6),
         .oe_i (w_7),
         .we_i (w_8),
         .addr_i (w_1),
         .data_i (w_2),
         .dataout (w_11),
         .datadir (w_12)
     );


endmodule
