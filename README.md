README

CHAMPIONCHIP STAGE 3 - PROJECT FILE DIRECTORY GUIDE

This directory contains the design files, firmware builders, testbenches, and 
hardware implementation packages for Stage 3.


1. DIRECTORY STRUCTURE
-------------------------------------------------------------------------------
Project file/
|-- 01 UART & GPIO/
|   |-- 01 UART & GPIO Block/
|   |   |-- gpio.v
|   |   `-- uart.v
|   |-- 02 RVBL-GPIO-UART-Test-Firmware/
|   |   |-- rtl/ (SoC RTL: top.v, Stage3_RISCV.v, gpio.v, uart.v)
|   |   |-- testbench/ (testbench.v, simulation.log, testbench.vcd)
|   |   |-- pinData/ (FPGA pin constraint files)
|   |   `-- logs/ (Synthesis logs)
|   |-- 03 Testbenches-GPIO-UART/
|   |   |-- tb_gpio.v
|   |   `-- tb_uart.v
|   `-- hdl_netlist.v
|
`-- 02 Application/
    |-- 01 RVBL-Firmware-Builder-Raw/
    |   |-- Makefile
    |   |-- bsp/custom.ld
    |   |-- scripts/bin2rom.py
    |   `-- src/main.s
    |-- 02 RVBL-Firmware-Builder-Result/
    |   |-- build/firmware.bin
    |   |-- build/firmware.dmp
    |   |-- build/firmware.elf
    |   |-- build/firmware.txt
    |   |-- build/main.o
    |   `-- src/main.s
    |-- 03 Full Hardware Implementation/
    |   |-- rtl/ (SoC RTL with embedded application firmware)
    |   |-- testbench/ (Application testbench, simulation.log, testbench.vcd)
    |   |-- pinData/ (FPGA pin constraint files)
    |   `-- logs/ (Synthesis logs)
    |-- hdl_netlist.v
    `-- main.s


2. FOLDER EXPLANATION
-------------------------------------------------------------------------------

[01 UART & GPIO]
Contains baseline peripheral IP blocks, peripheral unit testbenches, and the 
official firmware verification setup.

  * 01 UART & GPIO Block/
    - gpio.v: 8-bit bidirectional GPIO controller (DATAOUT, DATAIN, DATADIR).
    - uart.v: 115,200 baud 8-N-1 serial UART controller.

  * 02 RVBL-GPIO-UART-Test-Firmware/
    - ChipInventor project running official competition firmware.
    - hdl.v: Verilog.
    - testbench.v: Testbench.
    - simulation.log: Testbench result.

  * 03 Testbenches-GPIO-UART/
    - tb_gpio.v: Standalone unit testbench verifying 5 GPIO test cases (100% pass).
    - tb_uart.v: Standalone unit testbench verifying 6 UART test cases (100% pass).

  * hdl_netlist.v:
    - Gate-level synthesized netlist of the baseline SoC.


[02 Application]
Contains the custom Edge-AI application design, firmware build toolchain, 
pre-compiled ROM files, and full hardware implementation.

  * 01 RVBL-Firmware-Builder-Raw/
    - Clean compilation environment to assemble RISC-V firmware.
    - src/main.s: Source assembly for the Edge-AI application.
    - bsp/custom.ld: Linker script mapping code to instruction memory (0x00400000).
    - Makefile: Build script calling RISC-V GCC toolchain.
    - scripts/bin2rom.py: Converts binary firmware into Verilog ROM format.

  * 02 RVBL-Firmware-Builder-Result/
    - Compiled firmware outputs:
      * build/firmware.bin: Machine code binary.
      * build/firmware.dmp: Assembly disassembly listing.
      * build/firmware.elf: Linked ELF executable.
      * build/firmware.txt: Verilog hex ROM array for chip embedding.
      * build/main.o: Compiled object file.
      * src/main.s: Application source code.

  * 03 Full Hardware Implementation/
    - ChipInventor project for the Edge-AI SoC application.
    - hdl.v: Verilog.
    - testbench.v: Testbench.
    - simulation.log: Testbench result.

  * hdl_netlist.v:
    - Gate-level synthesized netlist of the complete Edge-AI SoC.

  * main.s:
    - Top-level copy of the Edge-AI RISC-V assembly firmware source.
===============================================================================
