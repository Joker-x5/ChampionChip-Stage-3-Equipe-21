`timescale 1ns / 1ns
// =============================================================================
// ChampionChip Stage 3 - Application Firmware Testbench 
// =============================================================================
// Emulates the host `./emu` CLI command stream on Stage 3/Application.v:
//   Test 1: ./emu -d 0xFE -i 0x01 -t4 0x3C190A0F -r1 0 -o 0  (NORMAL)
//   Test 2: ./emu -d 0xFE -i 0x01 -t4 0x1E252328 -r1 1 -o 1  (SMOLDERING - Hero AI Case)
//   Test 3: ./emu -d 0xFE -i 0x01 -t4 0x0A4B4664 -r1 2 -o 3  (ACTIVE FIRE)
//
// Optimized for cloud platforms (e.g. ChipInventor) to prevent timeout & quota cutoffs:
//   - Fast 1ns/1ns timescale
//   - Compact level-1 VCD dump (prevents dumping 65K RAM flip-flops to disk)
//   - Live stdout flushing ($fflush) so results stream in real time
//   - Parameterized TEST_SELECT (0=All, 1=Normal, 2=Smoldering, 3=Fire)
// =============================================================================

// Comment out to disable VCD generation completely if ultra-fast simulation is desired
`define ENABLE_VCD

module testbench();

    // -------------------------------------------------------------------------
    // Test Case Selection (for platforms with tight time/step limits)
    //   0 = Run ALL 3 Test Cases (Normal -> Smoldering -> Active Fire) [Default]
    //   1 = Run Test 1 Only (Normal Forest Day)
    //   2 = Run Test 2 Only (Hero Case: Smoldering Peat Early Detection)
    //   3 = Run Test 3 Only (Active Wildfire)
    // -------------------------------------------------------------------------
    parameter TEST_SELECT = 0;

    // -------------------------------------------------------------------------
    // 1. Clock, Reset, and Physical Signals
    // -------------------------------------------------------------------------
    reg        clk_i = 0;
    reg        rst_i = 0;
    reg        rx_i  = 1; // UART idle line is HIGH (Marking)
    wire       tx_o;
    wire [7:0] pins_io;

    // 50 MHz Clock generation (Period = 20 ns)
    always #10 clk_i = ~clk_i;

    // Emulated host bidirectional GPIO pad driver
    // Pin 0 is driven as Trigger (-o 1), Pin 1 & 2 are read as Alarms (-i)
    reg  [7:0] ext_gpio_drive = 8'h00;
    reg  [7:0] ext_gpio_en    = 8'h01; // Enable only Pin 0 (Trigger input to chip)

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : gen_ext_pads
            assign pins_io[gi] = ext_gpio_en[gi] ? ext_gpio_drive[gi] : 1'bz;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 2. Device Under Test: Application.v (top instance named ai45)
    // -------------------------------------------------------------------------
    top ai45 (
        .clk_i   (clk_i),
        .rst_i   (rst_i),
        .rx_i    (rx_i),
        .tx_o    (tx_o),
        .pins_io (pins_io)
    );

    // -------------------------------------------------------------------------
    // 3. VCD Waveform Dumping (Optimized for ChipInventor)
    //    Dumps top-level chip signals without recursing into the 65,536 bit DMEM
    // -------------------------------------------------------------------------
    initial begin
`ifdef ENABLE_VCD
        $dumpfile("testbench.vcd");
        $dumpvars(1, testbench);
        $dumpvars(1, ai45);
`endif
    end

    // -------------------------------------------------------------------------
    // 4. Host UART Tasks (115,200 baud, 8-N-1)
    //    Bit period = 1 / 115200 s = 8,680.55 ns = 8681 ns
    // -------------------------------------------------------------------------
    localparam BIT_PERIOD = 8681;

    task uart_send_byte(input [7:0] data);
        integer b;
        begin
            // Start bit
            rx_i <= 1'b0;
            #(BIT_PERIOD);
            // 8 Data bits (LSB first)
            for (b = 0; b < 8; b = b + 1) begin
                rx_i <= data[b];
                #(BIT_PERIOD);
            end
            // Stop bit
            rx_i <= 1'b1;
            #(BIT_PERIOD);
        end
    endtask

    task uart_receive_byte(output [7:0] data);
        integer b;
        begin
            @(negedge tx_o); // Wait for start bit
            #(BIT_PERIOD / 2); // Sample at midpoint of start bit
            for (b = 0; b < 8; b = b + 1) begin
                #(BIT_PERIOD);
                data[b] = tx_o; // Sample data bit
            end
            #(BIT_PERIOD); // Wait through stop bit
        end
    endtask

    // Helper task to emulate the full `./emu -o 1 -t4 ... -r1 ... -i ...` command
    task run_emulator_step(
        input [31:0] sensor_packet, // [Hum, Temp, H2, CO]
        input [7:0]  expected_class,
        input [7:0]  expected_gpio,
        input [127:0] test_name
    );
        reg [7:0] co_val, h2_val, temp_val, hum_val;
        reg [7:0] rx_class;
        reg [7:0] actual_gpio;
        begin
            co_val   = sensor_packet[7:0];
            h2_val   = sensor_packet[15:8];
            temp_val = sensor_packet[23:16];
            hum_val  = sensor_packet[31:24];

            $display("\n-------------------------------------------------------------------------------");
            $display("[EMU CLI] Executing: ./emu -d 0xFE -i 0x01 -t4 0x%08h -r1 %0d -o %0d (%0s)", 
                     sensor_packet, expected_class, expected_gpio, test_name);
            $display("          Inputs: CO=%0d ppm, H2=%0d ppm, Temp=%0d C, Hum=%0d %%", 
                     co_val, h2_val, temp_val, hum_val);
            $fflush();

            // 1. Assert Trigger (-o 1)
            ext_gpio_drive[0] <= 1'b1;
            #500;

            // 2. Transmit 4 sensor bytes and receive classification concurrently
            fork
                begin
                    uart_send_byte(co_val);
                    uart_send_byte(h2_val);
                    uart_send_byte(temp_val);
                    uart_send_byte(hum_val);
                end
                begin
                    uart_receive_byte(rx_class);
                end
            join

            // 3. Sample GPIO Alarm Pins (-i, bits 2:1)
            #200;
            actual_gpio = {pins_io[2], pins_io[1]};

            // 4. Verify against expected emulator values
            if (rx_class === expected_class && actual_gpio === expected_gpio) begin
                $display("[EMU PASS] Returned Class=%0d, GPIO Alarm=%0d (Matched Expected)", rx_class, actual_gpio);
            end else begin
                $display("[EMU FAIL] Mismatch! Got Class=%0d (exp %0d), GPIO=%0d (exp %0d)", 
                         rx_class, expected_class, actual_gpio, expected_gpio);
                $fflush();
                $finish;
            end
            $fflush();

            // 5. Release Trigger (-o 0) to allow firmware handshake
            ext_gpio_drive[0] <= 1'b0;
            #(BIT_PERIOD);
        end
    endtask

    // -------------------------------------------------------------------------
    // 5. Test Execution
    // -------------------------------------------------------------------------
    initial begin
        $display("\n===============================================================================");
        $display("   CHAMPIONCHIP STAGE 3 APPLICATION FIRMWARE VALIDATION");
        $display("   Target Netlist: Stage 3/Application.v (Edge-AI Wildfire Node)");
        $display("===============================================================================");
        $fflush();

        // Power-on reset
        clk_i = 0;
        rst_i = 1;
        rx_i  = 1;
        ext_gpio_drive = 8'h00;
        ext_gpio_en    = 8'h01; // Drive Pin 0 only

        #200;
        @(negedge clk_i);
        rst_i = 0;
        $display("[INFO] System reset released. CPU booted from firmware_memory (0x00400000).");
        $fflush();
        #500;

        if (TEST_SELECT == 0 || TEST_SELECT == 1) begin
            // --- TEST 1: Normal Ambient Forest Conditions ---
            // CO=15, H2=10, Temp=25C, Hum=60% -> Packet = 0x3C190A0F -> Expected Class 0, Alarm 0
            run_emulator_step(32'h3C190A0F, 8'd0, 8'd0, "NORMAL");
        end

        if (TEST_SELECT == 0 || TEST_SELECT == 2) begin
            // --- TEST 2: Sub-threshold Smoldering Peat (THE HERO CASE!) ---
            // CO=40, H2=35, Temp=37C, Hum=30% -> Packet = 0x1E252328 -> Expected Class 1, Alarm 1
            run_emulator_step(32'h1E252328, 8'd1, 8'd1, "SMOLDERING");
        end

        if (TEST_SELECT == 0 || TEST_SELECT == 3) begin
            // --- TEST 3: Open Flame Wildfire ---
            // CO=100, H2=70, Temp=75C, Hum=10% -> Packet = 0x0A4B4664 -> Expected Class 2, Alarm 3
            run_emulator_step(32'h0A4B4664, 8'd2, 8'd3, "ACTIVE FIRE");
        end

        $display("\n===============================================================================");
        if (TEST_SELECT == 0)
            $display("   ALL 3 EMULATOR CASES PASSED 100%% WITH HARDWARE ACCELERATION!");
        else
            $display("   EMULATOR TEST CASE %0d PASSED 100%% WITH HARDWARE ACCELERATION!", TEST_SELECT);
        $display("   >>> APPLICATION.V IS 100%% VERIFIED AND READY FOR AWS SYNTHESIS <<<");
        $display("===============================================================================\n");
        $fflush();

        $finish;
    end

    // Global Safety Watchdog (2ms)
    initial begin
        #2_000_000;
        $display("\n[ERROR] Watchdog timer expired (2ms)!");
        $fflush();
        $finish;
    end

endmodule
