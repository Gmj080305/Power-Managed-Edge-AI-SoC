// clk_rst_ctrl.sv - clock and reset control (PD_AON).
// clk_sys = clk_in (OPP-H) or clk_in/2 (OPP-L) through a glitch-free switch.
// PD_AON runs on ungated clk_sys; PD_CMP and PD_MEM get gated copies.
// One root clock keeps every bus crossing synchronous; only the 32 kHz wake
// timer is a separate (asynchronous) clock domain.
module clk_rst_ctrl (
  input  logic clk_in,
  input  logic por_n,
  input  logic test_en,
  input  logic freq_lo,       // from PMU (clk_sys domain)
  input  logic cmp_clk_en,
  input  logic mem_clk_en,
  input  logic cmp_rst_n,     // from PMU
  input  logic mem_rst_n,
  output logic clk_sys,
  output logic clk_cmp,
  output logic clk_mem,
  output logic rst_sys_n,
  output logic rst_cmp_n,
  output logic rst_mem_n,
  output logic freq_lo_ack,   // f/2 drives clk_sys (synchronised)
  output logic freq_hi_ack    // f   drives clk_sys (synchronised)
);
  logic clk_div2;
  always_ff @(posedge clk_in or negedge por_n)
    if (!por_n) clk_div2 <= 1'b0; else clk_div2 <= ~clk_div2;

  logic sel0_q, sel1_q;
  clk_switch u_sw (.clk0(clk_in), .clk1(clk_div2), .rst_n(por_n), .sel(freq_lo),
                   .clk_out(clk_sys), .sel0_q(sel0_q), .sel1_q(sel1_q));

  rst_sync u_rst (.clk(clk_sys), .arst_n(por_n), .rst_n(rst_sys_n));

  logic [1:0] sel_s;
  sync_2ff #(.W(2), .RST_VAL(1)) u_sel_sync (.clk(clk_sys), .rst_n(rst_sys_n),
                                             .d({sel1_q, sel0_q}), .q(sel_s));
  assign freq_hi_ack = sel_s[0] & ~sel_s[1];
  assign freq_lo_ack = sel_s[1] & ~sel_s[0];

  icg u_icg_cmp (.clk(clk_sys), .en(cmp_clk_en), .test_en(test_en), .gclk(clk_cmp));
  icg u_icg_mem (.clk(clk_sys), .en(mem_clk_en), .test_en(test_en), .gclk(clk_mem));

  assign rst_cmp_n = rst_sys_n & cmp_rst_n;
  assign rst_mem_n = rst_sys_n & mem_rst_n;
endmodule
