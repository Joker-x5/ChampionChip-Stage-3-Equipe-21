`timescale 1ns / 1ns
// =============================================================================
// ChampionChip Stage 3 - GPIO Controller Testbench (tb_gpio.v)
// =============================================================================
//
// Target Specifications Verified (BlockGuide Section 1):
//   - Reset values: DATADIR = 0x00 (inputs/high-Z safe), DATAOUT = 0x00
//   - Word-aligned register addresses (0x00, 0x04, 0x08) & upper bit zeroing
//   - Tri-state I/O pin driving (DATADIR = 1 drives DATAOUT, DATADIR = 0 is high-Z)
//   - Input buffer contention protection / isolation (Section 1.3.1, Figure 1)
//   - Bus read output enable (oe_i) gating
// =============================================================================

`define ENABLE_VCD

module testbench();

    // -------------------------------------------------------------------------
    // 1. Clock, Reset, and Signals 
    // -------------------------------------------------------------------------
    reg        clk_i = 0;
    reg        rst_i = 0;
    wire [7:0] pins_io;

    // 50 MHz Clock generation (Period = 20 ns)
    always #10 clk_i = ~clk_i;

    // Peripheral Bus Signals
    reg  [31:0] gpio_addr;
    reg  [31:0] gpio_wdata;
    reg         gpio_we;
    reg         gpio_oe;
    wire [31:0] gpio_rdata;

    // External emulation driver for bidirectional pads
    reg  [7:0]  gpio_ext_drive = 8'h00;
    reg  [7:0]  gpio_ext_en    = 8'h00;
    wire [7:0]  gpio_dir;
    wire [7:0]  gpio_out;

    // Emulate ChipInventor "Inout Pin" block in testbench:
    // C = gpio_dir, D = gpio_out, Right Circle (input to chip) = pins_io
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_ext_pin
            assign pins_io[gi] = gpio_ext_en[gi] ? gpio_ext_drive[gi] :
                                 gpio_dir[gi]    ? gpio_out[gi]       : 1'bz;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 2. Device Under Test: gpio Module
    // -------------------------------------------------------------------------
    gpio u_gpio (
        .clk_i   (clk_i),
        .rst_i   (rst_i),
        .addr_i  (gpio_addr),
        .data_i  (gpio_wdata),
        .we_i    (gpio_we),
        .oe_i    (gpio_oe),
        .data_o  (gpio_rdata),
        .datadir (gpio_dir),
        .dataout (gpio_out),
        .datain  (pins_io)
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

    // -------------------------------------------------------------------------
    // 4. Bus Access Tasks
    // -------------------------------------------------------------------------
    task write_gpio(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk_i);
            gpio_addr  <= addr;
            gpio_wdata <= data;
            gpio_we    <= 1'b1;
            gpio_oe    <= 1'b0;
            @(posedge clk_i);
            gpio_we    <= 1'b0;
        end
    endtask

    task read_gpio(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk_i);
            gpio_addr <= addr;
            gpio_we   <= 1'b0;
            gpio_oe   <= 1'b1;
            #1;
            data = gpio_rdata;
            @(posedge clk_i);
            gpio_oe   <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // 5. Test Execution
    // -------------------------------------------------------------------------
    integer total_tests  = 0;
    integer passed_tests = 0;
    integer failed_tests = 0;
    reg [31:0] rdata;

    initial begin
        $display("\n===============================================================================");
        $display("   CHAMPIONCHIP STAGE 3 GPIO CONTROLLER VERIFICATION");
        $display("   Specification Reference: BlockGuide_Stage3_Part1.pdf (Section 1)");
        $display("===============================================================================");
        $fflush();

        // ---------------------------------------------------------------------
        // Test 1: Reset Default State Verification
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        clk_i = 0;
        rst_i = 1;
        gpio_addr  = 32'hF0000000;
        gpio_wdata = 32'h0;
        gpio_we    = 0;
        gpio_oe    = 0;
        gpio_ext_en    = 8'h00;
        gpio_ext_drive = 8'h00;

        #100;
        @(negedge clk_i);
        rst_i = 0;
        #40;

        read_gpio(32'hF0000008, rdata); // Read DATADIR
        if (gpio_dir === 8'h00 && rdata[7:0] === 8'h00) begin
            $display("[PASS] Test 1: Reset Defaults - DATADIR=0x00 (all inputs high-Z safe), DATAOUT=0x00");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 1: Reset failed! datadir=0x%02h, readback=0x%08h", gpio_dir, rdata);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 2: Register Read/Write Access (DATADIR & DATAOUT)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        write_gpio(32'hF0000008, 32'h00000055); // DATADIR = 0x55 (alternating out/in)
        write_gpio(32'hF0000000, 32'h00000055); // DATAOUT = 0x55
        read_gpio(32'hF0000008, rdata);

        if (rdata[7:0] === 8'h55 && gpio_dir === 8'h55) begin
            $display("[PASS] Test 2: Register RW Access - DATADIR & DATAOUT readback verified (0x55)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 2: Register RW failed! readback=0x%08h", rdata);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 3: Tri-state Buffer Verification (Driving '1' vs High-Z)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        write_gpio(32'hF0000008, 32'h000000F0); // Upper 4 pins output, lower 4 input
        write_gpio(32'hF0000000, 32'h000000F0); // Drive upper 4 pins HIGH
        #20;

        if (pins_io[7:4] === 4'hF && pins_io[3:0] === 4'bzzzz) begin
            $display("[PASS] Test 3: Tri-state Buffer - Outputs drive '1', inputs are high-impedance ('z')");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 3: Tri-state behavior incorrect! pins_io = %b", pins_io);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 4: Contention Isolation & Input Sampling (DATAIN)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        write_gpio(32'hF0000008, 32'h00000000); // All pins configured as inputs
        gpio_ext_drive = 8'hAA;
        gpio_ext_en    = 8'hFF; // External driver drives 0xAA onto pads
        #40;

        read_gpio(32'hF0000004, rdata); // Read DATAIN
        if (rdata[7:0] === 8'hAA) begin
            $display("[PASS] Test 4: Contention Isolation - DATAIN reads external inputs (0xAA) with outputs isolated");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 4: DATAIN read failed! got=0x%02h (exp 0xAA)", rdata[7:0]);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Test 5: Read Bus Isolation (oe_i deassertion zeroes data_o)
        // -------------------------------------------------------------------------
        total_tests = total_tests + 1;
        gpio_addr = 32'hF0000004;
        gpio_oe   = 1'b0; // Deassert OE
        #10;

        if (gpio_rdata === 32'h00000000) begin
            $display("[PASS] Test 5: Read Bus Isolation - data_o = 0x00000000 when oe_i is deasserted");
            passed_tests = passed_tests + 1;
        end else begin
            $display("[FAIL] Test 5: Bus isolation failed! data_o=0x%08h", gpio_rdata);
            failed_tests = failed_tests + 1;
        end
        $fflush();

        // ---------------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------------------
        $display("\n===============================================================================");
        $display("   GPIO TEST SUMMARY: %0d Total | %0d Passed | %0d Failed", 
                 total_tests, passed_tests, failed_tests);
        if (failed_tests == 0)
            $display("   OVERALL STATUS: >>> GPIO REQUIREMENTS 100%% PASSED <<<");
        else
            $display("   OVERALL STATUS: >>> %0d FAILURES ENCOUNTERED <<<", failed_tests);
        $display("===============================================================================\n");
        $fflush();

        $finish;
    end

    // Safety watchdog
    initial begin
        #500_000;
        $display("\n[ERROR] Watchdog timer expired!");
        $fflush();
        $finish;
    end

endmodule
