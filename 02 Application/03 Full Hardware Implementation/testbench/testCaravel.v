 entrou module top ( ---( 
 module 
  --- 
  
   input wire clk_i, ---inputwireclk_i, 
 clk_i 
   input wire rst_i, ---inputwirerst_i, 
 rst_i 
   input wire rx_i, ---inputwirerx_i, 
 rx_i 
   output wire tx_o, ---outputwiretx_o, 
 tx_o 
   inout wire [7:0] pins_io ---inoutwire[7:0] 
 pins_io 
  --- 
  
 ); --- 
 ); 
  --- 
  
 //Internal Wires --- 
 //Internal 
  wire [31:0] w_1; ---[31:0]w_1; 
  
  wire [31:0] w_2; ---[31:0]w_2; 
  
  wire w_3; ---w_3; 
  
  wire w_4; ---w_4; 
  
  wire [31:0] w_5; ---[31:0]w_5; 
  
  wire [31:0] w_6; ---[31:0]w_6; 
  
  wire w_7; ---w_7; 
  
  wire w_8; ---w_8; 
  
  wire [7:0] w_11; ---[7:0]w_11; 
  
  wire [7:0] w_12; ---[7:0]w_12; 
  
  --- 
  
 //Interface Assigns --- 
 //Interface 
  genvar gi; ---gi; 
  
  generate --- 
  
      for (gi = 0; gi < 8; gi = gi + 1) begin : gen_pins_io --- 
  
          assign pins_io[gi] = w_12[gi] ? w_11[gi] : 1'bz; --- 
  
      end --- 
  
  endgenerate --- 
  
  --- 
  
 //Instances of Modules ---Modules 
 //Instances 
 uart #(.CLK_FREQ(50_000_000), .BAUD_RATE(115200), .AUTO_TX_ON_WRITE(1)) blk4650_3 ( ---.BAUD_RATE(115200),.AUTO_TX_ON_WRITE(1))blk4650_3 
 blk4650_3uart 
          .clk_i (clk_i), --- 
  
          .rst_i (rst_i), --- 
  
          .rx_i (rx_i), --- 
  
          .tx_o (tx_o), --- 
  
          .addr_i (w_1), --- 
  
          .data_i (w_2), --- 
  
          .we_i (w_3), --- 
  
          .oe_i (w_4), --- 
  
          .data_o (w_5) --- 
  
      ); --- 
  
  --- 
  
 Stage3_RISCV blk4658_9 ( ---( 
 Stage3_RISCV 
          .clk_i (clk_i), --- 
  
          .rst_i (rst_i), --- 
  
          .address_o (w_1), --- 
  
          .data_o (w_2), --- 
  
          .uart_we_o (w_3), --- 
  
          .uart_oe_o (w_4), --- 
  
          .uart (w_5), --- 
  
          .gpio (w_6), --- 
  
          .gpio_oe_o (w_7), --- 
  
          .gpio_we_o (w_8) --- 
  
      ); --- 
  
  --- 
  
 gpio blk4659_18 ( ---( 
 gpio 
          .clk_i (clk_i), --- 
  
          .rst_i (rst_i), --- 
  
          .datain (pins_io[7:0]), --- 
  
          .data_o (w_6), --- 
  
          .oe_i (w_7), --- 
  
          .we_i (w_8), --- 
  
          .addr_i (w_1), --- 
  
          .data_i (w_2), --- 
  
          .dataout (w_11), --- 
  
          .datadir (w_12) --- 
  
      ); --- 
  
  --- 
  
  --- 
  
 endmodule --- 
 endmodule 
  --- 
  
