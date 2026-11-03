// pmu_formal.sv - formal harness for pmu_fsm.
//
// Every input is unconstrained except where an environment model says how
// real hardware behaves: power switches, the regulator and the clock switch
// respond to their controls after an arbitrary delay. The solver may issue
// any register request at any time, any wake event, and any acknowledge
// pattern - including the nasty ones (wake in the middle of a power-down,
// requests while busy, illegal targets).
//
// Properties use immediate assertions in clocked blocks so they work with
// the open-source Yosys front end (no SVA sequence support needed).
module pmu_formal (
  input logic       clk,
  // Free inputs: the solver chooses any value on every cycle.
  input logic       req_valid,
  input logic [2:0] req_target,
  input logic [2:0] wake_mask,
  input logic [7:0] seq_wait,
  input logic       ev_timer,
  input logic       ev_gpio,
  input logic       ev_host,
  input logic       ack_any,     // quiesce acknowledge timing
  input logic       step_c,      // CMP switch progress
  input logic       step_m,      // MEM switch progress
  input logic       step_v,      // regulator progress
  input logic       step_f       // clock-switch progress
);
  // ------------------------------------------------ reset for one cycle
  logic init = 1'b1;
  always @(posedge clk) init <= 1'b0;
  logic rst_n;
  assign rst_n = ~init;

  // Small step delays keep the proof depth manageable; the logic does not
  // depend on the value beyond "zero or more cycles".
  always @(*) assume (seq_wait <= 8'd2);

  // ------------------------------------------------ DUT
  logic        busy, err_pulse, timer_arm, wake_start;
  logic [1:0]  pstate, wake_from;
  logic [2:0]  wake_src;
  logic        freq_lo, freq_lo_ack, freq_hi_ack, vsel_hi, vdd_ok;
  logic        cmp_pwr_req, cmp_pwr_ack, cmp_clk_en, cmp_iso, cmp_rst_n;
  logic        cmp_sw_en, cmp_sw_ack, cmp_save, cmp_restore, cmp_restored;
  logic        mem_clk_en, mem_iso, mem_rst_n, mem_sw_en, mem_sw_ack;

  // The domain only acknowledges a quiesce request it has received.
  assign cmp_pwr_ack = ack_any & cmp_pwr_req;

  pmu_fsm dut (.*);

  // ------------------------------------------------ environment models
  // Power switches: ack moves to en after an arbitrary number of cycles.
  logic c_ack_q = 1'b1, m_ack_q = 1'b1;
  always @(posedge clk) begin
    if (!rst_n) begin
      c_ack_q <= 1'b1;
      m_ack_q <= 1'b1;
    end else begin
      if (step_c) c_ack_q <= cmp_sw_en;
      if (step_m) m_ack_q <= mem_sw_en;
    end
  end
  assign cmp_sw_ack = c_ack_q;
  assign mem_sw_ack = m_ack_q;

  // Regulator: output level follows vsel after an arbitrary delay.
  logic level_hi = 1'b1;
  always @(posedge clk) begin
    if (!rst_n)      level_hi <= 1'b1;
    else if (step_v) level_hi <= vsel_hi;
  end
  assign vdd_ok = (level_hi == vsel_hi);

  // Glitch-free clock switch: break before make, arbitrary latency.
  logic cur_lo = 1'b0, mid = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      cur_lo <= 1'b0;
      mid    <= 1'b0;
    end else if (freq_lo != cur_lo && !mid) begin
      mid <= 1'b1;                       // old clock disabled
    end else if (mid && step_f) begin
      mid    <= 1'b0;                    // new clock enabled
      cur_lo <= freq_lo;
    end
  end
  assign freq_hi_ack = ~mid & ~cur_lo;
  assign freq_lo_ack = ~mid &  cur_lo;

  // ------------------------------------------------ properties
  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;

  always @(posedge clk) begin
    if (rst_n) begin
      // P1-P2: a switched-off domain is always isolated
      a_cmp_off_iso:  assert (cmp_sw_en  || cmp_iso);
      a_mem_off_iso:  assert (mem_sw_en  || mem_iso);
      // P3: isolation stays on until the switch reports power good
      a_cmp_pg_iso:   assert (cmp_sw_ack || cmp_iso);
      a_mem_pg_iso:   assert (mem_sw_ack || mem_iso);
      // P4: the illegal state CMP-on / MEM-off is never requested
      a_no_illegal:   assert (!cmp_sw_en || mem_sw_en);
      // P5: no clock and reset held while a domain is switched off
      a_cmp_off_clk:  assert (cmp_sw_en || (!cmp_clk_en && !cmp_rst_n));
      a_mem_off_clk:  assert (mem_sw_en || (!mem_clk_en && !mem_rst_n));
      // P6: full speed only at full voltage (requested and actual)
      a_fhi_req_vhi:  assert (freq_lo  || vsel_hi);
      a_fhi_act_vhi:  assert (!freq_hi_ack || (vsel_hi && level_hi));
      // P7: save with the domain frozen but powered and not yet isolated
      a_save_ok:      assert (!cmp_save || (!cmp_clk_en && !cmp_iso && cmp_sw_ack));
      // P8: restore only into a powered, clocked, out-of-reset domain
      a_restore_ok:   assert (!cmp_restore || (cmp_sw_ack && cmp_clk_en && cmp_rst_n));
      // P9: isolation released only after power good and restore
      if (past_valid && $past(rst_n) && $past(cmp_iso) && !cmp_iso)
        a_iso_release: assert (cmp_sw_ack && cmp_restored);
      if (past_valid && $past(rst_n) && $past(mem_iso) && !mem_iso)
        a_mem_iso_rel: assert (mem_sw_ack && mem_rst_n && mem_clk_en);
      // P10: frequency only raised once the higher voltage is confirmed
      if (past_valid && $past(rst_n) && $past(freq_lo) && !freq_lo)
        a_f_after_v:   assert (vsel_hi && vdd_ok);

      // Reachability (proves the assertions are not vacuously true)
      c_active_l: cover (pstate == 2'd1 && !busy);
      c_idle:     cover (pstate == 2'd2 && !busy);
      c_sleep:    cover (pstate == 2'd3 && !busy);
      c_err:      cover (err_pulse);
      c_wake_slp: cover (wake_start && wake_from == 2'd3);
      c_back_l:   cover (past_valid && $past(busy) && !busy && pstate == 2'd1 && wake_src != 3'd0);
    end
  end
endmodule
