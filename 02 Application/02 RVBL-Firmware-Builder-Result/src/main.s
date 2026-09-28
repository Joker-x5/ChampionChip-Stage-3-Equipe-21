# =============================================================================
# ChampionChip Stage 3 - Edge-AI Wildfire Early Detection Firmware (app.s)
# =============================================================================
# Application:
#   Multivariate Edge-AI Wildfire & Smoldering Early Detection Node.
#   Monitors 4 environmental gas and climate variables (CO, H2, Temp, Humidity)
#   using an on-chip Neural Network (int8 MLP with ReLU activation) running
#   on the Stage 2 Hardware Multiplier (mul instruction).
#
# Register Map:
#   s0 = UART Base Address (0xF1000000)
#   s1 = GPIO Base Address (0xF0000000)
#   s2 = CO (Carbon Monoxide in ppm)
#   s3 = H2 (Hydrogen in ppm, peat pyrolysis signature)
#   s4 = Temp (Temperature in deg C)
#   s5 = Hum (Relative Humidity in %)
#   s6 = z0 (Neuron 0: Normal Ambient Activation)
#   s7 = z1 (Neuron 1: Smoldering Pattern Activation - HERO CASE)
#   s8 = z2 (Neuron 2: Open Flame / Fire Activation)
#
# Memory Mapped Registers Used:
#   GPIO:
#     0xF0000000 (DATAOUT) : [1:0] Alarm level LEDs (0=Quiet, 1=Yellow, 3=Red)
#     0xF0000004 (DATAIN)  : [0] Trigger from Host / Emulator (-o 1)
#     0xF0000008 (DATADIR) : 0xFE (Pin 0 Input, Pins 1-7 Output)
#   UART:
#     0xF1000000 (TXDATA)  : Send Classification result (0=Normal, 1=Smolder, 2=Fire)
#     0xF1000004 (RXDATA)  : Read incoming sensor frame bytes (-t4)
#     0xF1000008 (CONTROL) : [1] RXDONE, [2] TXDONE
# =============================================================================

    .section .text
    .globl _start

_start:
    # -------------------------------------------------------------------------
    # 1. Peripheral Initialization
    # -------------------------------------------------------------------------
    lui  s0, 0xF1000           # s0 = 0xF1000000 (UART Base)
    lui  s1, 0xF0000           # s1 = 0xF0000000 (GPIO Base)

    # Configure GPIO Direction: Pin 0 Input, Pins [7:1] Output
    addi t0, zero, 254         # 0xFE = 8'b11111110
    sw   t0, 8(s1)             # Write DATADIR

    # Clear all initial alarms
    sw   zero, 0(s1)           # Write DATAOUT = 0

# =============================================================================
# 2. Main Application Loop: Wait for Emulator Trigger (-o 1)
# =============================================================================
wait_trigger:
    lw   t0, 4(s1)             # Read GPIO DATAIN (0xF0000004)
    andi t0, t0, 1             # Mask Pin 0 (Trigger bit)
    beq  t0, zero, wait_trigger # Wait until Trigger is asserted high

# =============================================================================
# 3. Read 4-Byte Sensor Frame from UART (-t4)
#    Sequence: [CO, H2, Temp, Hum]
# =============================================================================

# --- Byte 0: Carbon Monoxide (CO) ---
read_co:
    lw   t0, 8(s0)             # Read UART CONTROL
    andi t0, t0, 2             # Check RXDONE (bit 1)
    beq  t0, zero, read_co     # Poll until byte received
    sw   zero, 8(s0)           # Clear RXDONE
    lw   s2, 4(s0)             # s2 = CO reading

# --- Byte 1: Hydrogen (H2) ---
read_h2:
    lw   t0, 8(s0)
    andi t0, t0, 2
    beq  t0, zero, read_h2
    sw   zero, 8(s0)
    lw   s3, 4(s0)             # s3 = H2 reading

# --- Byte 2: Temperature (Temp) ---
read_temp:
    lw   t0, 8(s0)
    andi t0, t0, 2
    beq  t0, zero, read_temp
    sw   zero, 8(s0)
    lw   s4, 4(s0)             # s4 = Temperature reading

# --- Byte 3: Relative Humidity (Hum) ---
read_hum:
    lw   t0, 8(s0)
    andi t0, t0, 2
    beq  t0, zero, read_hum
    sw   zero, 8(s0)
    lw   s5, 4(s0)             # s5 = Humidity reading

# =============================================================================
# 4. Micro-Neural Network Inference (Multivariate Pattern Detection)
# =============================================================================

    # -------------------------------------------------------------------------
    # Neuron 0: Ambient / Normal Forest Detector
    # Formula: z0 = ReLU(2*Hum - CO - H2 - Temp)
    # -------------------------------------------------------------------------
    slli t0, s5, 1             # t0 = 2 * Hum
    sub  t0, t0, s2            # t0 = 2*Hum - CO
    sub  t0, t0, s3            # t0 = 2*Hum - CO - H2
    sub  t0, t0, s4            # t0 = 2*Hum - CO - H2 - Temp
    bgez t0, z0_pos
    addi t0, zero, 0           # ReLU Activation: max(0, t0)
z0_pos:
    addi s6, t0, 0             # s6 = z0 score

    # -------------------------------------------------------------------------
    # Neuron 1: Smoldering Peat Combustion Detector (HERO CASE!)
    # Formula: z1 = ReLU(3*CO + 4*H2 + Temp - 2*Hum - 120)
    # USES STAGE 2 HARDWARE MULTIPLIER (mul)!
    # -------------------------------------------------------------------------
    addi t1, zero, 3
    mul  t0, s2, t1            # t0 = 3 * CO (HARDWARE MULTIPLIER)
    addi t1, zero, 4
    mul  t2, s3, t1            # t2 = 4 * H2 (HARDWARE MULTIPLIER)
    add  t0, t0, t2            # t0 = 3*CO + 4*H2
    add  t0, t0, s4            # + Temp
    slli t1, s5, 1             # t1 = 2 * Hum
    sub  t0, t0, t1            # - 2*Hum
    addi t0, t0, -120          # - 120
    bgez t0, z1_pos
    addi t0, zero, 0           # ReLU Activation: max(0, t0)
z1_pos:
    addi s7, t0, 0             # s7 = z1 score

    # -------------------------------------------------------------------------
    # Neuron 2: Open Flame / Rapid Combustion Detector
    # Formula: z2 = ReLU(2*CO + 3*Temp - 4*Hum - 200)
    # USES STAGE 2 HARDWARE MULTIPLIER (mul)!
    # -------------------------------------------------------------------------
    slli t0, s2, 1             # t0 = 2 * CO
    addi t1, zero, 3
    mul  t2, s4, t1            # t2 = 3 * Temp (HARDWARE MULTIPLIER)
    add  t0, t0, t2            # t0 = 2*CO + 3*Temp
    slli t1, s5, 2             # t1 = 4 * Hum
    sub  t0, t0, t1            # - 4*Hum
    addi t0, t0, -200          # - 200
    bgez t0, z2_pos
    addi t0, zero, 0           # ReLU Activation: max(0, t0)
z2_pos:
    addi s8, t0, 0             # s8 = z2 score

# =============================================================================
# 5. Classification Decision Logic & Output Dispatch
# =============================================================================
    bgtz s8, is_fire           # If z2 > 0 -> Priority FIRE
    blt  s6, s7, is_smold      # If z1 > z0 -> SMOLDERING ALERT

    # --- Class 0: NORMAL ---
    addi a0, zero, 0           # Return Class: 0 (Normal)
    addi a1, zero, 0           # GPIO Alarm: 0x00 (All quiet)
    jal  zero, send_out

    # --- Class 1: SMOLDERING (Early Warning) ---
is_smold:
    addi a0, zero, 1           # Return Class: 1 (Smoldering)
    addi a1, zero, 2           # GPIO Alarm: 0x02 (Yellow Warning LED on Pin 1)
    jal  zero, send_out

    # --- Class 2: ACTIVE FIRE ---
is_fire:
    addi a0, zero, 2           # Return Class: 2 (Fire)
    addi a1, zero, 6           # GPIO Alarm: 0x06 (Red Siren / Flasher on Pins 2:1)

send_out:
    # 1. Set Physical GPIO Alarm Pins (-i)
    sw   a1, 0(s1)             # Write DATAOUT (0xF0000000)

    # 2. Transmit Classification Byte via UART (-r1)
    sw   a0, 0(s0)             # Write TXDATA (0xF1000000, triggers TX)

    # 3. Wait for UART TXDONE (bit 2 of CONTROL)
wait_tx:
    lw   t0, 8(s0)             # Read UART CONTROL
    andi t0, t0, 4             # Mask bit 2 (TXDONE)
    beq  t0, zero, wait_tx     # Wait until TXDONE == 1

    # -------------------------------------------------------------------------
    # 6. Handshake: Wait for Host to de-assert Trigger before next cycle
    # -------------------------------------------------------------------------
wait_release:
    lw   t0, 4(s1)             # Read GPIO DATAIN
    andi t0, t0, 1             # Check Trigger bit
    bne  t0, zero, wait_release # Wait until Trigger drops back to 0

    jal  zero, wait_trigger    # Ready for next detection sample!
