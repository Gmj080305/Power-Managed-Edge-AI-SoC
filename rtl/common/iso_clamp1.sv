// iso_clamp1.sv - isolation cell, output clamped to 1 while iso = 1
// (for active-low or idle-high signals such as a UART TX line).
// SKY130_ISO: sky130_fd_sc_hd__lpflow_inputiso1p_1, function X = A | SLEEP.
// NO_ISOLATION (single-domain baseline): a wire.
module iso_clamp1 #(
  parameter int W = 1
) (
  input  logic         iso,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
`ifdef NO_ISOLATION
  // Single-domain baseline: no power management hardware at all.
  assign q = d;
`elsif SKY130_ISO
  for (genvar i = 0; i < W; i++) begin : g_bit
    (* keep *) sky130_fd_sc_hd__lpflow_inputiso1p_1 u_iso (.A(d[i]), .SLEEP(iso), .X(q[i]));
  end
`else
  assign q = iso ? '1 : d;
`endif
endmodule
