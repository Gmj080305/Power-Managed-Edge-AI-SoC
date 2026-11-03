// mac_pe.sv - one processing element of the output-stationary systolic array.
// Each cycle: acc += a_in * b_in (signed INT8 x INT8 -> INT32), and the
// operands are forwarded right (a) and down (b) through registers.
module mac_pe (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               clr,     // synchronous clear of acc and pipes
  input  logic signed [7:0]  a_in,
  input  logic signed [7:0]  b_in,
  output logic signed [7:0]  a_out,
  output logic signed [7:0]  b_out,
  output logic signed [31:0] acc
);
  logic signed [15:0] prod;
  assign prod = a_in * b_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else if (clr) begin
      a_out <= '0;
      b_out <= '0;
      acc   <= '0;
    end else begin
      a_out <= a_in;
      b_out <= b_in;
      acc   <= acc + 32'(prod);
    end
  end
endmodule
