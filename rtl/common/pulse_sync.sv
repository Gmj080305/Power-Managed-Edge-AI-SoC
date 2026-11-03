// pulse_sync.sv - destination half of a toggle synchroniser.
// The source domain flips `tgl` once per event; this module turns each flip
// into a one-cycle pulse in the destination clock domain.
module pulse_sync (
  input  logic clk,
  input  logic rst_n,
  input  logic tgl,
  output logic pulse
);
  logic s;
  logic s_d;
  sync_2ff u_sync (.clk(clk), .rst_n(rst_n), .d(tgl), .q(s));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s_d <= 1'b0;
    else        s_d <= s;
  end
  assign pulse = s ^ s_d;
endmodule
