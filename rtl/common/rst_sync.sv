// rst_sync.sv - asynchronous assert, synchronous de-assert reset.
module rst_sync (
  input  logic clk,
  input  logic arst_n,
  output logic rst_n
);
  logic s1;
  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) begin
      s1    <= 1'b0;
      rst_n <= 1'b0;
    end else begin
      s1    <= 1'b1;
      rst_n <= s1;
    end
  end
endmodule
