// aon_top.sv - PD_AON: PMU, DVFS clocking, wake logic, retention shadow and
// register file. Never powered off. Everything arriving from PD_CMP passes a
// low->high level shifter then an isolation cell clamped to 0.
module aon_top (
  input  logic        clk_in,
  input  logic        clk_32k,
  input  logic        por_n,
  input  logic        test_en,
  input  logic        gpio_wake,
  input  logic        host_wake,
  // clocks / resets out
  output logic        clk_sys,
  output logic        clk_cmp,
  output logic        clk_mem,
  output logic        rst_cmp_n,
  output logic        rst_mem_n,
  // bus from PD_CMP (raw, before LS/ISO)
  input  logic        cmp_valid,
  input  logic [31:0] cmp_addr,
  input  logic [31:0] cmp_wdata,
  input  logic [3:0]  cmp_wstrb,
  output logic [31:0] cmp_rdata,
  output logic        cmp_ready,
  // power management to / from PD_CMP (raw)
  input  logic        cmp_pwr_ack_raw,
  input  logic [8:0]  ret_cfg_raw,
  input  logic        cmp_trap_raw,
  output logic        cmp_pwr_req,
  output logic        cmp_restore,
  output logic [8:0]  ret_cfg_shadow,
  output logic        cmp_iso,
  output logic        mem_iso,
  output logic        cmp_trap,
  // off-chip regulator and power switches
  output logic        vsel_hi,
  input  logic        vdd_ok,
  output logic        sw_en_cmp,
  input  logic        sw_ack_cmp,
  output logic        sw_en_mem,
  input  logic        sw_ack_mem
);
  // ------------------------------------------------ clocks and resets
  logic rst_sys_n, freq_lo, freq_lo_ack, freq_hi_ack;
  logic cmp_clk_en, mem_clk_en, cmp_rst_req_n, mem_rst_req_n;

  clk_rst_ctrl u_clk (
    .clk_in(clk_in), .por_n(por_n), .test_en(test_en), .freq_lo(freq_lo),
    .cmp_clk_en(cmp_clk_en), .mem_clk_en(mem_clk_en),
    .cmp_rst_n(cmp_rst_req_n), .mem_rst_n(mem_rst_req_n),
    .clk_sys(clk_sys), .clk_cmp(clk_cmp), .clk_mem(clk_mem),
    .rst_sys_n(rst_sys_n), .rst_cmp_n(rst_cmp_n), .rst_mem_n(rst_mem_n),
    .freq_lo_ack(freq_lo_ack), .freq_hi_ack(freq_hi_ack));

  logic rst_32k_n;
  rst_sync u_rst32 (.clk(clk_32k), .arst_n(por_n), .rst_n(rst_32k_n));

  // ------------------------------------------------ receive from PD_CMP
  localparam int RW = 1 + 32 + 32 + 4 + 1 + 9 + 1;
  logic [RW-1:0] rx_ls, rx_iso;
  ls_lh      #(.W(RW)) u_ls  (.d({cmp_valid, cmp_addr, cmp_wdata, cmp_wstrb,
                                  cmp_pwr_ack_raw, ret_cfg_raw, cmp_trap_raw}), .q(rx_ls));
  iso_clamp0 #(.W(RW)) u_iso (.iso(cmp_iso), .d(rx_ls), .q(rx_iso));

  logic        b_valid, pwr_ack;
  logic [31:0] b_addr, b_wdata;
  logic [3:0]  b_wstrb;
  logic [8:0]  ret_cfg_in;
  assign {b_valid, b_addr, b_wdata, b_wstrb, pwr_ack, ret_cfg_in, cmp_trap} = rx_iso;

  // ------------------------------------------------ wake sources
  logic [1:0] pin_s, pin_d;
  sync_2ff #(.W(2)) u_pin_sync (.clk(clk_sys), .rst_n(rst_sys_n),
                                .d({host_wake, gpio_wake}), .q(pin_s));
  always_ff @(posedge clk_sys or negedge rst_sys_n)
    if (!rst_sys_n) pin_d <= 2'b00; else pin_d <= pin_s;

  logic ev_gpio, ev_host, ev_timer, timer_arm;
  assign ev_gpio = pin_s[0] & ~pin_d[0];
  assign ev_host = pin_s[1] & ~pin_d[1];

  logic [23:0] wake_period;
  wake_timer u_timer (.clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .clk_32k(clk_32k),
                      .rst_32k_n(rst_32k_n), .arm(timer_arm), .period(wake_period),
                      .ev(ev_timer));

  // ------------------------------------------------ regulator / switch handshakes
  // vdd_ok (regulator) and sw_ack_* (power switches) come from analog or
  // off-chip blocks with no timing relationship to clk_sys, so they are
  // synchronised before the PMU or the registers use them (found by corner
  // STA: unsynchronised, they were timed as synchronous inputs). Reset value 1
  // = the power-on state: regulator settled, both domains switched on.
  logic vdd_ok_s, sw_ack_cmp_s, sw_ack_mem_s;
  sync_2ff #(.W(3), .RST_VAL(3'b111)) u_ack_sync (.clk(clk_sys), .rst_n(rst_sys_n),
    .d({vdd_ok, sw_ack_cmp, sw_ack_mem}), .q({vdd_ok_s, sw_ack_cmp_s, sw_ack_mem_s}));

  // ------------------------------------------------ PMU
  logic       req_valid, busy, err_pulse, wake_start;
  logic [2:0] req_target, wake_mask, wake_src;
  logic [1:0] pstate, wake_from;
  logic [7:0] seq_wait;
  logic       cmp_save, cmp_restored;

  pmu_fsm u_pmu (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .req_valid(req_valid), .req_target(req_target), .wake_mask(wake_mask),
    .seq_wait(seq_wait), .busy(busy), .err_pulse(err_pulse), .pstate(pstate),
    .timer_arm(timer_arm), .ev_timer(ev_timer), .ev_gpio(ev_gpio), .ev_host(ev_host),
    .wake_start(wake_start), .wake_src(wake_src), .wake_from(wake_from),
    .freq_lo(freq_lo), .freq_lo_ack(freq_lo_ack), .freq_hi_ack(freq_hi_ack),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok_s),
    .cmp_pwr_req(cmp_pwr_req), .cmp_pwr_ack(pwr_ack),
    .cmp_clk_en(cmp_clk_en), .cmp_iso(cmp_iso), .cmp_rst_n(cmp_rst_req_n),
    .cmp_sw_en(sw_en_cmp), .cmp_sw_ack(sw_ack_cmp_s),
    .cmp_save(cmp_save), .cmp_restore(cmp_restore), .cmp_restored(cmp_restored),
    .mem_clk_en(mem_clk_en), .mem_iso(mem_iso), .mem_rst_n(mem_rst_req_n),
    .mem_sw_en(sw_en_mem), .mem_sw_ack(sw_ack_mem_s));

  // ------------------------------------------------ retention shadow
  always_ff @(posedge clk_sys or negedge rst_sys_n)
    if (!rst_sys_n)    ret_cfg_shadow <= 9'd0;
    else if (cmp_save) ret_cfg_shadow <= ret_cfg_in;

  // ------------------------------------------------ registers
  aon_regs u_regs (
    .clk(clk_sys), .rst_n(rst_sys_n),
    .valid(b_valid & (b_addr[31:28] == soc_pkg::RGN_AON)), .addr(b_addr[7:0]),
    .wdata(b_wdata), .wstrb(b_wstrb), .rdata(cmp_rdata), .ready(cmp_ready),
    .req_valid(req_valid), .req_target(req_target), .wake_period(wake_period),
    .wake_mask(wake_mask), .seq_wait(seq_wait), .pstate(pstate), .busy(busy),
    .err_pulse(err_pulse), .wake_start(wake_start), .wake_src(wake_src),
    .wake_from(wake_from), .freq_lo_ack(freq_lo_ack), .vsel_hi(vsel_hi),
    .vdd_ok(vdd_ok_s), .cmp_sw_en(sw_en_cmp), .mem_sw_en(sw_en_mem),
    .ret_shadow(ret_cfg_shadow));
endmodule
