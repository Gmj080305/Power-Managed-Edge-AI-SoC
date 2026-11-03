// ls_lh.sv - low-to-high level shifter (PD_CMP at OPP-L ~1.50 V -> 1.80 V).
// Place it in the receiving domain, BEFORE the isolation cell.
// SKY130_LS: sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_4. Its LOWLVPWR pin
// must be connected to the low supply (VDD_CMP) by the multi-domain PDN
// script; the single-domain flows leave SKY130_LS undefined.
module ls_lh #(
  parameter int W = 1
) (
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
`ifdef SKY130_LS
  for (genvar i = 0; i < W; i++) begin : g_bit
    (* keep *) sky130_fd_sc_hd__lpflow_lsbuf_lh_isowell_4 u_ls (.A(d[i]), .X(q[i]));
  end
`else
  assign q = d;
`endif
endmodule
