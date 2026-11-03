// regulator_model.sv - off-chip buck regulator for VDD_CMP.
// vsel_hi = 1 -> 1.80 V, 0 -> 1.50 V. After a change the output slews for
// SETTLE cycles; vdd_ok is low from the cycle vsel changes until settled.
`timescale 1ns/1ps
module regulator_model #(
  parameter int SETTLE = 20
) (
  input  logic clk,
  input  logic rst_n,
  input  logic vsel_hi,
  output logic vdd_ok,
  output int   vdd_mv     // for waveforms: 1800 or 1500
);
  logic level_hi;   // level the output has settled at
  int   cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      level_hi <= 1'b1;
      cnt      <= 0;
    end else if (vsel_hi != level_hi) begin
      if (cnt == SETTLE - 1) begin
        level_hi <= vsel_hi;
        cnt      <= 0;
      end else begin
        cnt <= cnt + 1;
      end
    end else begin
      cnt <= 0;
    end
  end

  assign vdd_ok  = (vsel_hi == level_hi);
  assign vdd_mv  = level_hi ? 1800 : 1500;
endmodule
