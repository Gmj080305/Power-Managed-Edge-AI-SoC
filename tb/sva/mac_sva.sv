// mac_sva.sv - accelerator protocol checks, bound into mac_accel.
`timescale 1ns/1ps
module mac_sva (
  input logic       clk,
  input logic       rst_n,
  input logic       busy,
  input logic       mac_clk_en,
  input logic       start,
  input logic       done,
  input logic [1:0] state
);
  // Every property: sampled on the posedge clock edge, off while in reset.
`define CHK(prop) @(posedge clk) disable iff (!rst_n) (prop)

  // Clock gating: the array clock is off whenever the accelerator is idle.
  a_gated_idle : assert property (`CHK(!busy |-> !mac_clk_en));
  // done rises only when a job finishes (busy falls in the same cycle).
  a_done_end   : assert property (`CHK($rose(done) |-> $fell(busy)));
`undef CHK
endmodule

bind mac_accel mac_sva u_mac_sva (.clk(clk), .rst_n(rst_n), .busy(busy),
  .mac_clk_en(mac_clk_en), .start(start), .done(done), .state(state));
