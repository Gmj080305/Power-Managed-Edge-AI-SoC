// icg.sv - integrated clock gate.
// SKY130_CELLS maps to sky130_fd_sc_hd__dlclkp_1 (latch-based, glitch-free).
// Otherwise a behavioural model: the enable is captured on the falling edge
// and ANDed with the clock. For an enable launched by rising-edge flops this
// behaves exactly like the cell's low-transparent latch (the enable is
// stable through the low phase), stays glitch-free, and simulates in every
// simulator, including cycle-based ones that cannot settle latch loops.
module icg (
  input  logic clk,
  input  logic en,
  input  logic test_en,
  output logic gclk
);
`ifdef SKY130_CELLS
  sky130_fd_sc_hd__dlclkp_1 u_cg (.CLK(clk), .GATE(en | test_en), .GCLK(gclk));
`else
  logic en_l;
  always_ff @(negedge clk) en_l <= en | test_en;
  assign gclk = clk & en_l;
`endif
endmodule
