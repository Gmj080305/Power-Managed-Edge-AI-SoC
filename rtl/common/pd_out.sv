// pd_out.sv - marks a signal leaving a switchable power domain.
// Synthesis: a wire. Simulation with +define+PWR_SIM: drives X while the
// domain's power-good is low, which is what a real powered-off driver does.
// That X must be stopped by isolation in the receiving domain.
module pd_out #(
  parameter int W = 1
) (
  input  logic         pwr_good,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
`ifdef PWR_SIM
  assign q = pwr_good ? d : 'x;
`else
  assign q = d;
`endif
endmodule
