// pmu_fsm.sv - power management unit sequencer (PD_AON).
//
// Stable states (pstate): ACTIVE_H, ACTIVE_L, IDLE, SLEEP (see soc_pkg).
// Every power transition is a fixed sequence of steps; each step changes one
// control output, waits at least seq_wait cycles, then waits for its
// acknowledge. All control outputs are registered (no decode glitches).
//
//  DVFS H->L : freq low -> (ack) -> voltage low -> (vdd_ok)
//  DVFS L->H : voltage high -> (vdd_ok) -> freq high -> (ack)
//  CMP down  : quiesce req -> (ack) -> clock off -> save -> isolate
//              -> reset -> switch off -> (switch ack low)
//  MEM down  : clock off -> isolate -> reset -> switch off      (SLEEP only)
//  MEM up    : switch on -> (ack) -> clock on -> reset release -> iso off
//  CMP up    : switch on -> (ack) -> clock on -> reset release -> restore
//              -> iso off
//
// Save comes BEFORE isolation here because the retention shadow sits in
// PD_AON and reads the PD_CMP register across the boundary; with in-place
// retention flops (UPF set_retention) save could follow isolation.
// MEM is always powered before CMP and after it, so "CMP on, MEM off"
// cannot occur (proved in formal/).
// On power-up the clock runs for seq_wait cycles with reset still asserted:
// the CPU core uses a synchronous reset, which needs clock edges to take
// effect. (Releasing reset with the clock gated would leave it un-reset.)
module pmu_fsm (
  input  logic       clk,
  input  logic       rst_n,
  // requests (PMU_CTRL write)
  input  logic       req_valid,
  input  logic [2:0] req_target,
  input  logic [2:0] wake_mask,     // bit0 timer, bit1 gpio, bit2 host
  input  logic [7:0] seq_wait,
  output logic       busy,
  output logic       err_pulse,
  output logic [1:0] pstate,
  // wake
  output logic       timer_arm,     // pulse: (re)start the wake timer
  input  logic       ev_timer,
  input  logic       ev_gpio,
  input  logic       ev_host,
  output logic       wake_start,    // pulse: a wake sequence begins
  output logic [2:0] wake_src,      // sources that caused the last wake
  output logic [1:0] wake_from,     // state the last wake started from
  // DVFS
  output logic       freq_lo,       // clock switch select (1 = f/2)
  input  logic       freq_lo_ack,   // f/2 confirmed driving clk_sys
  input  logic       freq_hi_ack,   // f confirmed driving clk_sys
  output logic       vsel_hi,       // regulator select (1 = 1.80 V)
  input  logic       vdd_ok,        // regulator settled at the selected level
  // PD_CMP control
  output logic       cmp_pwr_req,
  input  logic       cmp_pwr_ack,
  output logic       cmp_clk_en,
  output logic       cmp_iso,
  output logic       cmp_rst_n,
  output logic       cmp_sw_en,
  input  logic       cmp_sw_ack,
  output logic       cmp_save,
  output logic       cmp_restore,
  output logic       cmp_restored,
  // PD_MEM control
  output logic       mem_clk_en,
  output logic       mem_iso,
  output logic       mem_rst_n,
  output logic       mem_sw_en,
  input  logic       mem_sw_ack
);

  typedef enum logic [4:0] {
    S_STABLE,
    S_DV_FLO, S_DV_VLO, S_DV_VHI, S_DV_FHI,
    S_C_REQ, S_C_CLK, S_C_SAVE, S_C_ISO, S_C_RST, S_C_OFF,
    S_M_CLK, S_M_ISO, S_M_RST, S_M_OFF,
    S_M_ON, S_M_RSTREL, S_M_CLKON, S_M_ISOREL,
    S_C_ON, S_C_RSTREL, S_C_CLKON, S_C_RESTORE, S_C_ISOREL
  } st_t;

  st_t        state, nxt;
  logic       adv;
  logic [7:0] cnt;
  logic       tgt_sleep;      // current power-down goes to SLEEP
  logic       wake_pend;
  logic [2:0] pend_src;

  // ------------------------------------------------------------ requests
  logic req_ok, req_dv, req_down;
  logic [2:0] wake_ev;
  assign wake_ev = {ev_host, ev_gpio, ev_timer} & wake_mask;

  // In a power-down sequence (CMP or MEM down steps)
  logic down_seq;
  assign down_seq = (state == S_C_REQ) || (state == S_C_CLK) || (state == S_C_SAVE) ||
                    (state == S_C_ISO) || (state == S_C_RST) || (state == S_C_OFF) ||
                    (state == S_M_CLK) || (state == S_M_ISO) || (state == S_M_RST) ||
                    (state == S_M_OFF);

  logic active;
  assign active = (pstate == soc_pkg::PS_ACTIVE_H) || (pstate == soc_pkg::PS_ACTIVE_L);

  always_comb begin
    req_ok   = 1'b0;
    req_dv   = 1'b0;
    req_down = 1'b0;
    if (req_valid && state == S_STABLE && active && req_target[2] == 1'b0
        && req_target[1:0] != pstate) begin
      if (req_target[1:0] == soc_pkg::PS_ACTIVE_H || req_target[1:0] == soc_pkg::PS_ACTIVE_L) begin
        req_ok = 1'b1;
        req_dv = 1'b1;
      end else if (wake_mask != 3'b000) begin
        req_ok   = 1'b1;
        req_down = 1'b1;
      end
    end
  end

  // A request for the current state is a legal no-op; anything else that
  // is not accepted is flagged.
  assign err_pulse = req_valid && !req_ok &&
                     !(state == S_STABLE && active && req_target == {1'b0, pstate});

  // ------------------------------------------------------------ next step
  logic waited;
  assign waited = (cnt == 8'd0);

  always_comb begin
    nxt = state;
    adv = 1'b0;
    case (state)
      S_STABLE: begin
        if (req_dv) begin
          adv = 1'b1;
          if (req_target[1:0] == soc_pkg::PS_ACTIVE_L) nxt = S_DV_FLO;
          else                                nxt = S_DV_VHI;
        end else if (req_down) begin
          adv = 1'b1;
          nxt = S_C_REQ;
        end else if (wake_pend && pstate == soc_pkg::PS_IDLE) begin
          adv = 1'b1;
          nxt = S_C_ON;
        end else if (wake_pend && pstate == soc_pkg::PS_SLEEP) begin
          adv = 1'b1;
          nxt = S_M_ON;
        end
      end
      S_DV_FLO:    begin adv = waited & freq_lo_ack;  nxt = S_DV_VLO;  end
      S_DV_VLO:    begin adv = waited & vdd_ok;       nxt = S_STABLE;  end
      S_DV_VHI:    begin adv = waited & vdd_ok;       nxt = S_DV_FHI;  end
      S_DV_FHI:    begin adv = waited & freq_hi_ack;  nxt = S_STABLE;  end
      S_C_REQ:     begin adv = waited & cmp_pwr_ack;  nxt = S_C_CLK;   end
      S_C_CLK:     begin adv = waited;                nxt = S_C_SAVE;  end
      S_C_SAVE:    begin adv = waited;                nxt = S_C_ISO;   end
      S_C_ISO:     begin adv = waited;                nxt = S_C_RST;   end
      S_C_RST:     begin adv = waited;                nxt = S_C_OFF;   end
      S_C_OFF:     begin
                     adv = waited & ~cmp_sw_ack;
                     if (tgt_sleep) nxt = S_M_CLK;
                     else           nxt = S_STABLE;
                   end
      S_M_CLK:     begin adv = waited;                nxt = S_M_ISO;   end
      S_M_ISO:     begin adv = waited;                nxt = S_M_RST;   end
      S_M_RST:     begin adv = waited;                nxt = S_M_OFF;   end
      S_M_OFF:     begin adv = waited & ~mem_sw_ack;  nxt = S_STABLE;  end
      S_M_ON:      begin adv = waited & mem_sw_ack;   nxt = S_M_CLKON; end
      S_M_CLKON:   begin adv = waited;                nxt = S_M_RSTREL; end
      S_M_RSTREL:  begin adv = waited;                nxt = S_M_ISOREL; end
      S_M_ISOREL:  begin adv = waited;                nxt = S_C_ON;    end
      S_C_ON:      begin adv = waited & cmp_sw_ack;   nxt = S_C_CLKON; end
      S_C_CLKON:   begin adv = waited;                nxt = S_C_RSTREL; end
      S_C_RSTREL:  begin adv = waited;                nxt = S_C_RESTORE; end
      S_C_RESTORE: begin adv = waited;                nxt = S_C_ISOREL; end
      S_C_ISOREL:  begin adv = waited;                nxt = S_STABLE;  end
      default:     begin adv = 1'b1;                  nxt = S_STABLE;  end
    endcase
  end

  // ------------------------------------------------------------ sequencer
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_STABLE;
      cnt          <= 8'd0;
      pstate       <= soc_pkg::PS_ACTIVE_H;
      tgt_sleep    <= 1'b0;
      wake_pend    <= 1'b0;
      pend_src     <= 3'b000;
      timer_arm    <= 1'b0;
      wake_start   <= 1'b0;
      wake_src     <= 3'b000;
      wake_from    <= soc_pkg::PS_ACTIVE_H;
      freq_lo      <= 1'b0;
      vsel_hi      <= 1'b1;
      cmp_pwr_req  <= 1'b0;
      cmp_clk_en   <= 1'b1;
      cmp_iso      <= 1'b0;
      cmp_rst_n    <= 1'b1;
      cmp_sw_en    <= 1'b1;
      cmp_save     <= 1'b0;
      cmp_restore  <= 1'b0;
      cmp_restored <= 1'b1;
      mem_clk_en   <= 1'b1;
      mem_iso      <= 1'b0;
      mem_rst_n    <= 1'b1;
      mem_sw_en    <= 1'b1;
    end else begin
      // single-cycle pulses
      timer_arm   <= 1'b0;
      wake_start  <= 1'b0;
      cmp_save    <= 1'b0;
      cmp_restore <= 1'b0;

      if (cnt != 8'd0) cnt <= cnt - 8'd1;

      // Wake events count from the start of a power-down onwards.
      if (down_seq && |wake_ev) begin
        wake_pend <= 1'b1;
        pend_src  <= pend_src | wake_ev;
      end else if (state == S_STABLE && !active && |wake_ev) begin
        wake_pend <= 1'b1;
        pend_src  <= pend_src | wake_ev;
      end

      if (adv) begin
        state <= nxt;
        cnt   <= seq_wait;
        case (nxt)
          S_STABLE: begin
            case (state)
              S_DV_VLO:   pstate <= soc_pkg::PS_ACTIVE_L;
              S_DV_FHI:   pstate <= soc_pkg::PS_ACTIVE_H;
              S_C_OFF:    pstate <= soc_pkg::PS_IDLE;
              S_M_OFF:    pstate <= soc_pkg::PS_SLEEP;
              S_C_ISOREL: pstate <= freq_lo ? soc_pkg::PS_ACTIVE_L : soc_pkg::PS_ACTIVE_H;
              default:    ;
            endcase
          end
          S_DV_FLO:    freq_lo <= 1'b1;
          S_DV_VLO:    vsel_hi <= 1'b0;
          S_DV_VHI:    vsel_hi <= 1'b1;
          S_DV_FHI:    freq_lo <= 1'b0;
          S_C_REQ: begin
            cmp_pwr_req <= 1'b1;
            tgt_sleep   <= (req_target[1:0] == soc_pkg::PS_SLEEP);
            timer_arm   <= wake_mask[soc_pkg::WK_TIMER];
            wake_pend   <= 1'b0;
            pend_src    <= 3'b000;
          end
          S_C_CLK:     cmp_clk_en <= 1'b0;
          S_C_SAVE:    cmp_save   <= 1'b1;
          S_C_ISO:     cmp_iso    <= 1'b1;
          S_C_RST: begin
            cmp_rst_n    <= 1'b0;
            cmp_pwr_req  <= 1'b0;
            cmp_restored <= 1'b0;
          end
          S_C_OFF:     cmp_sw_en  <= 1'b0;
          S_M_CLK:     mem_clk_en <= 1'b0;
          S_M_ISO:     mem_iso    <= 1'b1;
          S_M_RST:     mem_rst_n  <= 1'b0;
          S_M_OFF:     mem_sw_en  <= 1'b0;
          S_M_ON,
          S_C_ON: begin
            if (state == S_STABLE) begin   // a wake starts here
              wake_start <= 1'b1;
              wake_src   <= pend_src | wake_ev;
              wake_from  <= pstate;
              wake_pend  <= 1'b0;
              pend_src   <= 3'b000;
            end
            if (nxt == S_M_ON) mem_sw_en <= 1'b1;
            else               cmp_sw_en <= 1'b1;
          end
          S_M_RSTREL:  mem_rst_n  <= 1'b1;
          S_M_CLKON:   mem_clk_en <= 1'b1;
          S_M_ISOREL:  mem_iso    <= 1'b0;
          S_C_RSTREL:  cmp_rst_n  <= 1'b1;
          S_C_CLKON:   cmp_clk_en <= 1'b1;
          S_C_RESTORE: begin
            cmp_restore  <= 1'b1;
            cmp_restored <= 1'b1;
          end
          S_C_ISOREL:  cmp_iso    <= 1'b0;
          default:     ;
        endcase
      end
    end
  end

  assign busy = (state != S_STABLE);

endmodule
