// iso_clamp0.sv - isolation cell, output clamped to 0 while iso = 1.
// Instantiate in the RECEIVING (still powered) domain.
// SKY130_ISO: sky130_fd_sc_hd__lpflow_isobufsrc_1, function X = A & !SLEEP.
// NO_ISOLATION (single-domain baseline): a wire.
module iso_clamp0 #(
  parameter int W = 1
) (
  input  logic         iso,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
`ifdef FAULT_NO_ISO
  // Fault injection for verification only: isolation removed. The power
  // tests must FAIL with this defined (proves the checks are live).
  assign q = d;
`elsif NO_ISOLATION
  // Single-domain baseline: no power management hardware at all.
  assign q = d;
`elsif SKY130_ISO
  for (genvar i = 0; i < W; i++) begin : g_bit
    (* keep *) sky130_fd_sc_hd__lpflow_isobufsrc_1 u_iso (.A(d[i]), .SLEEP(iso), .X(q[i]));
  end
`else
  assign q = iso ? '0 : d;
`endif
endmodule
