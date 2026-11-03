// mac_array.sv - N x N output-stationary INT8 systolic array.
// Row i receives A[i][k] on a_left[i] at cycle t = i + k; column j receives
// B[k][j] on b_top[j] at cycle t = j + k. PE(i,j) therefore sees the pair
// (A[i][k], B[k][j]) at cycle i + j + k and accumulates C[i][j].
// The whole array runs on a gated clock: when idle it burns no dynamic power.
module mac_array #(
  parameter int N = 4
) (
  input  logic                clk,      // gated array clock
  input  logic                rst_n,
  input  logic                clr,
  input  logic [N*8-1:0]      a_left,   // a_left[i*8 +: 8] feeds row i
  input  logic [N*8-1:0]      b_top,    // b_top[j*8 +: 8] feeds column j
  output logic [N*N*32-1:0]   acc_flat  // acc of PE(i,j) at [(i*N+j)*32 +: 32]
);
  logic [7:0] a_bus [N][N+1];  // a_bus[i][j] = operand entering PE(i,j)
  logic [7:0] b_bus [N+1][N];  // b_bus[i][j] = operand entering PE(i,j)

  for (genvar i = 0; i < N; i++) begin : g_row
    assign a_bus[i][0] = a_left[i*8 +: 8];
  end
  for (genvar j = 0; j < N; j++) begin : g_col
    assign b_bus[0][j] = b_top[j*8 +: 8];
  end

  for (genvar i = 0; i < N; i++) begin : g_r
    for (genvar j = 0; j < N; j++) begin : g_c
      logic signed [31:0] acc;
      mac_pe u_pe (
        .clk   (clk),
        .rst_n (rst_n),
        .clr   (clr),
        .a_in  (a_bus[i][j]),
        .b_in  (b_bus[i][j]),
        .a_out (a_bus[i][j+1]),
        .b_out (b_bus[i+1][j]),
        .acc   (acc)
      );
      assign acc_flat[(i*N+j)*32 +: 32] = acc;
    end
  end
endmodule
