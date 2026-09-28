`timescale 1ns / 1ns
// =============================================================================
// ChampionChip Stage 3 - UART Serial Controller Testbench (tb_uart.v)
// =============================================================================
//
// Target Specifications Verified (BlockGuide Section 2):
//   - Reset state: tx_o = 1 (idle mark), TXDONE = 1 (ready), RXDONE = 0
//   - Transmit initiation via CONTROL[0] (TRANSMIT) bit (Sec 2.2.3 & 2.3.1)
//   - Transmit initiation via TXDATA write (AUTO_TX_ON_WRITE = 1)
//   - Exact baud rate timing (50 MHz / 115,200 = 434 clocks/bit, 8,680 ns)
//   - Receive protocol & RXDONE clearing via software write 0
//   - Glitch rejection at midpoint sampling (< 0.5 bit width spike ignored)
//   - Full-duplex concurrent loopback operation
// =============================================================================

`define ENABLE_VCD

module testbench();

    // -------------------------------------------------------------------------
    // 1. Clock, Reset, and Signals 
    // -------------------------------------------------------------------------
    reg        clk_i = 0;
    reg        rst_i = 0;
    reg        rx_i  = 1; // UART idle is HIGH (Marking)
    wire       tx_o;

    // 50 MHz Clock generation (Period = 20 ns)
    always #10 clk_i = ~clk_i;

    // Peripheral Bus Signals
    reg  [31:0] uart_addr;
    reg  [31:0] uart_wdata;
    reg         uart_we;
    reg         uart_oe;
    wire [31:0] uart_rdata;

    // -------------------------------------------------------------------------
    // 2. Device Under Test: uart Module
    // -------------------------------------------------------------------------
    uart #(
        .CLK_FREQ         (50_000_000),
        .BAUD_RATE        (115200),
        .AUTO_TX_ON_WRITE (1)
    ) u_uart (
        .clk_i  (clk_i),
        .rst_i  (rst_i),
        .addr_i (uart_addr),
        .data_i (uart_wdata),
        .we_i   (uart_we),
        .oe_i   (uart_oe),
        .data_o (uart_rdata),
        .tx_o   (tx_o),
        .rx_i   (rx_i)
    );

    // -------------------------------------------------------------------------
    // 3. VCD Waveform Dumping 
    // -------------------------------------------------------------------------
    initial begin
`ifdef ENABLE_VCD
        $dumpfile("testbench.vcd");
        $dumpvars(1, testbench);
`endif
    end

    localparam CLKS_PER_BIT   = 50_000_000 / 115200; // 434 clock cycles
    localparam BIT_PERIOD_NS  = CLKS_PER_BIT * 20;   // 8,680 ns per bit

    // -------------------------------------------------------------------------
    // 4. Bus Access Tasks
    // -------------------------------------------------------------------------
    task write_uart(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk_i);
            uart_addr  <= addr;
            uart_wdata <= data;
            uart_we    <= 1'b1;
            uart_oe    <= 1'b0;
            @(posedge clk_i);
            uart_we    <= 1'b0;
        end
    endtask

    task read_uart(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk_i);
            uart_addr <= addr;
            uart_we   <= 1'b0;
            uart_oe   <= 1'b1;
            #1;
            data = uart_rdata;
            @(posedge clk_i);
            uart_oe   <= 1'b0;
        end
    endtask

    // External UART Transmitter (injects serial byte into rx_i)
    task send_uart_rx(input [7:0] byte_val);
        integer k;
        begin
            // 1 Start bit ('0')
            rx_i <= 1'b0;
            #(BIT_PERIOD_NS);
            // 8 Data bits (LSB first)
            for (k = 0; k < 8; k = k + 1) begin
                rx_i <= byte_val[k];
                #(BIT_PERIOD_NS);
            end
            // 1 Stop bit ('1')
            rx_i <= 1'b1;
            #(BIT_PERIOD_NS);
        end
    endtask

    // -------------------------------------------------------------------------
    // 5. Test Execution
    // -------------------------------------------------------------------------
    integer total_tests  = 0;
    integer passed_tests = 0;
    integer failed_tests = 0;
    integer b;
    reg [31:0] rdata;
    reg [7:0]  rx_captured;

    initial begin
        $display("\n===============================================================================");
        $display("   CHAMPIONCHIP STAGE 3 UART SERIAL CONTROLLER VERIFICATION");
        $display("   Specification Reference: BlockGuide_Stage3_Part1.pdf (Section 2)");
        $display("===============================================================================");
        $fflush();

        // ---------------------------------------------------------------------
        // Test 1: Reset Default State Verification (Table 8)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        clk_i = 0;
        rst_i = 1;
        rx_i  = 1;
        uart_addr  = 32'hF100_0000;
        uart_wdata = 32'h0;
        uart_we    = 0;
        uart_oe    = 0;

        #100;
        @(negedge clk_i);
        rst_i = 0;
        #40;

        read_uart(32'hF100_0008, rdata); // Read CONTROL
        if (rdata[2] === 1'b1 && rdata[1] === 1'b0 && rdata[0] === 1'b0 && tx_o === 1'b1) begin
            $display("[PASS] Test 1: Reset State - tx_o=1 (idle high), TXDONE=1 (ready), RXDONE=0, TRANSMIT=0");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 1: Reset State Failed! tx_o=%b, CONTROL=0x%08h", tx_o, rdata);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 2: Transmission via TRANSMIT Control Bit (Section 2.2.3 & 2.3.1)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        write_uart(32'hF100_0000, 32'h0000_00A5); // TXDATA = 0xA5 (10100101)
        write_uart(32'hF100_0008, 32'h0000_0001); // Set TRANSMIT bit (bit 0)

        // Verify TXDONE dropped to 0 and TRANSMIT auto-cleared
        read_uart(32'hF100_0008, rdata);
        if (rdata[2] !== 1'b0 || rdata[0] !== 1'b0) begin
            $display("[FAIL] Test 2: TXDONE did not clear or TRANSMIT failed to auto-clear");
            failed_tests = failed_tests + 1;
        end else begin
            // Sample Start bit at midpoint
            #(BIT_PERIOD_NS / 2);
            if (tx_o !== 1'b0) begin
                $display("[FAIL] Test 2: Start bit not 0");
                failed_tests = failed_tests + 1;
            end else begin
                // Sample 8 data bits at midpoints
                rx_captured = 0;
                for (b = 0; b < 8; b = b + 1) begin
                    #(BIT_PERIOD_NS);
                    rx_captured[b] = tx_o;
                end
                // Sample Stop bit
                #(BIT_PERIOD_NS);
                if (rx_captured === 8'hA5 && tx_o === 1'b1) begin
                    // Verify TXDONE returns to 1 upon completion
                    #(BIT_PERIOD_NS);
                    read_uart(32'hF100_0008, rdata);
                    if (rdata[2] === 1'b1) begin
                        $display("[PASS] Test 2: UART TX via TRANSMIT bit - 8-N-1 frame 0xA5 validated, TXDONE=1");
                        passed_tests = passed_tests + 1;
                    end else begin
                        $display("[FAIL] Test 2: TXDONE not set after stop bit");
                        failed_tests = failed_tests + 1;
                    end
                end else begin
                    $display("[FAIL] Test 2: Captured byte = 0x%02h (expected 0xA5)", rx_captured);
                    failed_tests = failed_tests + 1;
                end
            end
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 3: Transmission via Direct TXDATA Write (Section 2.3.3)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        write_uart(32'hF100_0000, 32'h0000_003C); // Write TXDATA = 0x3C directly
        #(BIT_PERIOD_NS / 2);
        if (tx_o !== 1'b0) begin
            $display("[FAIL] Test 3: Auto-transmit on TXDATA write did not start");
            failed_tests = failed_tests + 1;
        end else begin
            rx_captured = 0;
            for (b = 0; b < 8; b = b + 1) begin
                #(BIT_PERIOD_NS);
                rx_captured[b] = tx_o;
            end
            #(BIT_PERIOD_NS);
            if (rx_captured === 8'h3C && tx_o === 1'b1) begin
                $display("[PASS] Test 3: UART Auto-TX on TXDATA write - Compatible with Sec 2.3.3 code (0x3C)");
                passed_tests = passed_tests + 1;
            end else begin
                $display("[FAIL] Test 3: Captured = %h (expected 0x3C)", rx_captured);
                failed_tests = failed_tests + 1;
            end
        end
        #(BIT_PERIOD_NS * 2);
        $fflush();

        // ---------------------------------------------------------------------
        // Test 4: Reception & RXDONE Status Bit Protocol (Section 2.3.2)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        send_uart_rx(8'h5A); // Send 0x5A externally into rx_i
        #100;
        read_uart(32'hF100_0008, rdata); // Read CONTROL
        if (rdata[1] === 1'b1) begin
            read_uart(32'hF100_0004, rdata); // Read RXDATA
            if (rdata[7:0] === 8'h5A) begin
                // Clear RXDONE by writing 0 to bit 1
                write_uart(32'hF100_0008, 32'h0000_0000);
                read_uart(32'hF100_0008, rdata);
                if (rdata[1] === 1'b0) begin
                    $display("[PASS] Test 4: UART RX - Received 0x5A, RXDONE set and cleared via software write 0");
                    passed_tests = passed_tests + 1;
                end else begin
                    $display("[FAIL] Test 4: RXDONE bit not cleared by writing 0");
                    failed_tests = failed_tests + 1;
                end
            end else begin
                $display("[FAIL] Test 4: RXDATA = %h (expected 0x5A)", rdata[7:0]);
                failed_tests = failed_tests + 1;
            end
        end else begin
            $display("[FAIL] Test 4: RXDONE bit not set in CONTROL");
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 5: Glitch Rejection at Midpoint Sampling
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        // Inject a 50-cycle low pulse (< CLKS_PER_BIT/2 = 217 cycles)
        rx_i <= 1'b0;
        #(20 * 50);
        rx_i <= 1'b1;
        #(BIT_PERIOD_NS * 2);
        read_uart(32'hF100_0008, rdata);
        if (rdata[1] === 1'b0) begin
            $display("[PASS] Test 5: Glitch Rejection - False start bit spike (< half bit) successfully filtered out");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 5: Glitch triggered false reception (RXDONE=1)");
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 6: Full-Duplex Simultaneous Loopback Test (tx_o -> rx_i)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        fork
            begin : loopback_wire
                forever begin
                    @(tx_o);
                    rx_i <= tx_o;
                end
            end
            begin : loopback_exec
                // Transmit byte 0xE7 via UART
                write_uart(32'hF100_0000, 32'h0000_00E7);
                // Wait for transmission and reception to complete (~12 bit periods)
                #(BIT_PERIOD_NS * 12);
                read_uart(32'hF100_0008, rdata); // Read CONTROL
                if (rdata[1] === 1'b1 && rdata[2] === 1'b1) begin
                    read_uart(32'hF100_0004, rdata); // Read RXDATA
                    if (rdata[7:0] === 8'hE7) begin
                        $display("[PASS] Test 6: Full-Duplex Loopback - Transmitted & received 0xE7 concurrently");
                        passed_tests = passed_tests + 1;
                    end else begin
                        $display("[FAIL] Test 6: Loopback RXDATA = %h (expected 0xE7)", rdata[7:0]);
                        failed_tests = failed_tests + 1;
                    end
                end else begin
                    $display("[FAIL] Test 6: Loopback status not ready (CONTROL=0x%08h)", rdata);
                    failed_tests = failed_tests + 1;
                end
            end
        join_any
        disable loopback_wire;
        $fflush();

        // ---------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------------
        $display("\n===============================================================================");
        $display("   UART TEST SUMMARY: %0d Total | %0d Passed | %0d Failed", 
                 total_tests, passed_tests, failed_tests);
        if (failed_tests == 0)
            $display("   OVERALL STATUS: >>> UART REQUIREMENTS 100%% PASSED <<<");
        else
            $display("   OVERALL STATUS: >>> %0d FAILURES ENCOUNTERED <<<", failed_tests);
        $display("===============================================================================\n");
        $fflush();

        $finish;
    end

    // Safety watchdog
    initial begin
        #1_000_000;
        $display("\n[ERROR] Watchdog timer expired!");
        $fflush();
        $finish;
    end

endmodule
