// soc_if.sv - pins of the SoC plus a few observed internal signals.
// The testbench drives and samples on the FALLING edge of clk_sys, so it
// never races the DUT's rising-edge flops (portable alternative to a
// clocking block, which some simulators cannot drive through a virtual
// interface yet).
`timescale 1ns/1ps
interface soc_if (
  input logic clk_sys         // the SoC's own clock: follows DVFS
);
  // pins
  logic        por_n;
  logic        gpio_wake;
  logic        host_wake;
  logic        host_en;
  logic        host_valid;
  logic [31:0] host_addr;
  logic [31:0] host_wdata;
  logic [3:0]  host_wstrb;
  logic [31:0] host_rdata;
  logic        host_ready;
  logic        uart_tx;
  logic        cpu_trap;
  logic        vsel_hi;
  logic        vdd_ok;
  logic        sw_ack_cmp;
  logic        sw_ack_mem;
  // observed internals (assigned in tb_soc)
  logic [1:0]  pstate;
  logic        pmu_busy;
  logic        freq_lo_ack;
  logic        mac_clk_en;
  logic        uart_pass;
  logic        uart_fail;
endinterface
