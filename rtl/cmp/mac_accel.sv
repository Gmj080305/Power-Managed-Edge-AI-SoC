// mac_accel.sv - memory-mapped INT8 matrix-multiply accelerator.
//   C[N][N] = A[N][K] x B[K][N], 1 <= K <= N, optional ReLU on C.
// Register map (byte offsets, see soc_pkg):
//   0x000 CTRL    W  bit0 start
//   0x004 STATUS  R  bit0 busy, bit1 done (sticky, cleared by start)
//   0x008 CFG     RW [3:0] K (0 means N), bit8 ReLU          <- retained
//   0x00C CYCLES  R  cycles taken by the last job
//   0x010 INFO    R  [7:0] N
//   0x100 A       RW A[i][k] = byte (i*N + k), packed 4 per word
//   0x200 B       RW B[k][j] = byte (k*N + j)
//   0x400 C       R  C[i][j] = word (i*N + j)
// CFG is the retained register: the PMU copies it to an always-on shadow
// (cfg_q -> AON) before power-off and pulses `restore` after power-up.
module mac_accel #(
  parameter int N = 4
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        test_en,
  // bus slave
  input  logic        valid,
  input  logic [11:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,
  output logic        ready,
  // status / power management
  output logic        busy,
  output logic        mac_clk_en,   // observable for clock-gating checks
  output logic [8:0]  cfg_q,        // retained state, to AON shadow
  input  logic        restore,      // load cfg from shadow
  input  logic [8:0]  cfg_ret
);
  localparam int NN  = N * N;
  localparam int TW  = 6;           // cycle counter width (K+2N-2 <= 22)

  // ------------------------------------------------------------ storage
  // A and B are byte matrices packed 4 per word (row-major, row stride N).
  localparam int NW = (NN + 3) / 4;
  localparam int CW = $clog2(NN);
  localparam int WW = (NW > 1) ? $clog2(NW) : 1;
  logic [31:0] a_w   [NW];
  logic [31:0] b_w   [NW];
  logic [31:0] c_mem [NN];

  typedef enum logic [1:0] {S_IDLE, S_CLR, S_RUN, S_LATCH} state_t;
  state_t      state;
  logic [TW-1:0] t;
  logic [3:0]  k_eff;
  logic        done;
  logic [15:0] cycles, cyc_cnt;

  assign k_eff = (cfg_q[3:0] == 4'd0 || cfg_q[3:0] > 4'(N)) ? 4'(N) : cfg_q[3:0];
  assign busy  = (state != S_IDLE);

  // ------------------------------------------------------------ bus slave
  logic fire;
  bus_slave_ack u_ack (.clk(clk), .rst_n(rst_n), .valid(valid), .fire(fire), .ready(ready));

  logic wr, start;
  assign wr    = fire & (|wstrb);
  assign start = wr & (addr == soc_pkg::ACC_CTRL) & wdata[0] & (state == S_IDLE);

  logic [11:0] a_off, b_off, c_off;
  assign a_off = addr - soc_pkg::ACC_A_BASE;
  assign b_off = addr - soc_pkg::ACC_B_BASE;
  assign c_off = addr - soc_pkg::ACC_C_BASE;

  logic in_a, in_b, in_c;
  assign in_a = (addr >= soc_pkg::ACC_A_BASE) && (a_off < 12'(NW*4));
  assign in_b = (addr >= soc_pkg::ACC_B_BASE) && (b_off < 12'(NW*4));
  assign in_c = (addr >= soc_pkg::ACC_C_BASE) && (c_off < 12'(NN*4));

  logic [WW-1:0] a_idx, b_idx;
  logic [CW-1:0] c_idx;
  assign a_idx = a_off[2 +: WW];
  assign b_idx = b_off[2 +: WW];
  assign c_idx = c_off[2 +: CW];

  // CFG register (retained)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                       cfg_q <= 9'd0;
    else if (restore)                                 cfg_q <= cfg_ret;
    else if (wr && addr == soc_pkg::ACC_CFG && !busy) cfg_q <= {wdata[8], 4'b0000, wdata[3:0]};
  end

  // A / B buffers with byte-lane writes. No reset: contents are lost at
  // power-off and software reloads them.
  always_ff @(posedge clk) begin
    for (int l = 0; l < 4; l++) begin
      if (wr && in_a && wstrb[l]) a_w[a_idx][l*8 +: 8] <= wdata[l*8 +: 8];
      if (wr && in_b && wstrb[l]) b_w[b_idx][l*8 +: 8] <= wdata[l*8 +: 8];
    end
  end

  // Read mux (registered, captured in the `fire` cycle)
  logic [31:0] rd_mux;
  always_comb begin
    rd_mux = 32'h0;
    if (addr == soc_pkg::ACC_STATUS)      rd_mux = {30'h0, done, busy};
    else if (addr == soc_pkg::ACC_CFG)    rd_mux = {23'h0, cfg_q[8], 4'h0, cfg_q[3:0]};
    else if (addr == soc_pkg::ACC_CYCLES) rd_mux = {16'h0, cycles};
    else if (addr == soc_pkg::ACC_INFO)   rd_mux = {16'h0, 8'(N), 8'(N)};
    else if (in_a)                        rd_mux = a_w[a_idx];
    else if (in_b)                        rd_mux = b_w[b_idx];
    else if (in_c)                        rd_mux = c_mem[c_idx];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)    rdata <= 32'h0;
    else if (fire) rdata <= rd_mux;
  end

  // ------------------------------------------------------------ control FSM
  logic [TW-1:0] t_last;
  assign t_last = TW'(k_eff) + TW'(2*N - 3);   // last accumulate cycle

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      t       <= '0;
      done    <= 1'b0;
      cycles  <= '0;
      cyc_cnt <= '0;
    end else begin
      case (state)
        S_IDLE:  if (start) begin
                   state   <= S_CLR;
                   done    <= 1'b0;
                   cyc_cnt <= 16'd1;
                 end
        S_CLR:   begin
                   state   <= S_RUN;
                   t       <= '0;
                   cyc_cnt <= cyc_cnt + 16'd1;
                 end
        S_RUN:   begin
                   cyc_cnt <= cyc_cnt + 16'd1;
                   if (t == t_last) state <= S_LATCH;
                   else             t     <= t + 1'b1;
                 end
        default: begin  // S_LATCH
                   state  <= S_IDLE;
                   done   <= 1'b1;
                   cycles <= cyc_cnt + 16'd1;
                 end
      endcase
    end
  end

  // ------------------------------------------------------------ operand feed
  // Skewed injection: row i gets A[i][t-i], column j gets B[t-j][j], zero
  // outside 0 <= t-i < K so out-of-range cycles accumulate nothing.
  logic [N*8-1:0] a_left, b_top;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      a_left[i*8 +: 8] = 8'h00;
      b_top [i*8 +: 8] = 8'h00;
      for (int k = 0; k < N; k++) begin
        if (state == S_RUN && t == TW'(i + k) && k_eff > 4'(k)) begin
          a_left[i*8 +: 8] = a_w[(i*N + k) / 4][((i*N + k) % 4)*8 +: 8];
          b_top [i*8 +: 8] = b_w[(k*N + i) / 4][((k*N + i) % 4)*8 +: 8];
        end
      end
    end
  end

  // ------------------------------------------------------------ array
  logic mac_clk;
  logic [N*N*32-1:0] acc_flat;
  assign mac_clk_en = (state == S_CLR) || (state == S_RUN);

  icg u_icg (.clk(clk), .en(mac_clk_en), .test_en(test_en), .gclk(mac_clk));

  mac_array #(.N(N)) u_array (
    .clk      (mac_clk),
    .rst_n    (rst_n),
    .clr      (state == S_CLR),
    .a_left   (a_left),
    .b_top    (b_top),
    .acc_flat (acc_flat)
  );

  // Result latch with optional ReLU
  always_ff @(posedge clk) begin
    if (state == S_LATCH) begin
      for (int p = 0; p < NN; p++) begin
        c_mem[p] <= (cfg_q[8] && acc_flat[p*32+31]) ? 32'h0 : acc_flat[p*32 +: 32];
      end
    end
  end

`ifdef PWR_SIM
  // Power-off corruption: buffers have no reset, so model them going to X
  // while the domain is off (the domain reset is asserted before power-off).
  always @(negedge rst_n) begin
    for (int p = 0; p < NW; p++) begin
      a_w[p] = 'x;
      b_w[p] = 'x;
    end
    for (int p = 0; p < NN; p++) c_mem[p] = 'x;
  end
`endif

endmodule
