// soc_sva.sv - power-aware checks at the domain boundaries, bound into
// soc_top. The X checks need a 4-state simulator and +define+PWR_SIM.
`timescale 1ns/1ps
module soc_sva (
  input logic        clk,
  input logic        rst_n,
  input logic        cmp_iso,
  input logic        mem_iso,
  input logic        aon_rx_valid,
  input logic        mem_rx_valid,
  input logic [79:0] aon_rx,
  input logic [68:0] mem_rx,
  input logic        uart_tx,
  input logic        sw_ack_mem
);
  // Every property: sampled on the negedge clock edge, off while in reset.
`define CHK(prop) @(negedge clk) disable iff (!rst_n) (prop)

  // Isolated inputs sit at their clamp value
  a_aon_clamped : assert property (`CHK(cmp_iso |-> aon_rx == '0));
  a_mem_clamped : assert property (`CHK(cmp_iso && sw_ack_mem |-> mem_rx == '0));
  a_uart_idle   : assert property (`CHK(mem_iso |-> uart_tx == 1'b1));
`ifdef PWR_SIM
  // No X on a control signal entering a powered domain
  a_aon_no_x    : assert property (`CHK(!$isunknown(aon_rx_valid)));
  a_mem_no_x    : assert property (`CHK(sw_ack_mem |-> !$isunknown(mem_rx_valid)));
`endif
`undef CHK
endmodule

bind soc_top soc_sva u_soc_sva (.clk(u_aon.clk_sys), .rst_n(u_aon.rst_sys_n),
  .cmp_iso(cmp_iso), .mem_iso(mem_iso), .aon_rx_valid(u_aon.b_valid),
  .mem_rx_valid(u_mem.v), .aon_rx(u_aon.rx_iso), .mem_rx(u_mem.in_iso),
  .uart_tx(uart_tx), .sw_ack_mem(sw_ack_mem));
