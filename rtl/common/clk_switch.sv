// clk_switch.sv - glitch-free 2:1 clock multiplexer.
// sel = 0 selects clk0, sel = 1 selects clk1. Each side only enables its
// clock after the other side has been disabled on its own falling edge, so
// the output never sees a runt pulse. sel0_q / sel1_q report which clock is
// actually driving the output (both low for a few cycles during a switch).
module clk_switch (
  input  logic clk0,
  input  logic clk1,
  input  logic rst_n,
  input  logic sel,
  output logic clk_out,
  output logic sel0_q,
  output logic sel1_q
);
  logic q0a, q1a;

  always_ff @(posedge clk0 or negedge rst_n)
    if (!rst_n) q0a <= 1'b1; else q0a <= ~sel & ~sel1_q;
  always_ff @(negedge clk0 or negedge rst_n)
    if (!rst_n) sel0_q <= 1'b1; else sel0_q <= q0a;

  always_ff @(posedge clk1 or negedge rst_n)
    if (!rst_n) q1a <= 1'b0; else q1a <= sel & ~sel0_q;
  always_ff @(negedge clk1 or negedge rst_n)
    if (!rst_n) sel1_q <= 1'b0; else sel1_q <= q1a;

  assign clk_out = (clk0 & sel0_q) | (clk1 & sel1_q);
endmodule
