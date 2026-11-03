// pwr_switch_model.sv - header power switch (daisy chain) for one domain.
// ack follows en after DELAY cycles in both directions, like the last
// switch of a chain reporting back. pwr_good = ack.
`timescale 1ns/1ps
module pwr_switch_model #(
  parameter int DELAY = 8
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  output logic ack
);
  int cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ack <= 1'b1;   // domains are powered at power-on
      cnt <= 0;
    end else if (en != ack) begin
      if (cnt == DELAY - 1) begin
        ack <= en;
        cnt <= 0;
      end else begin
        cnt <= cnt + 1;
      end
    end else begin
      cnt <= 0;
    end
  end
endmodule
