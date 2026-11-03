// wake_timer.sv - 32.768 kHz wake timer with clock-domain crossing.
// clk_sys side: `arm` pulse flips arm_tgl; `ev` pulses when the timer
// expires. clk_32k side: each arm_tgl flip restarts the counter; on reaching
// `period` ticks it flips match_tgl once. Both flips cross through 2-flop
// synchronisers (toggle synchronisers). `period` is quasi-static: software
// writes it before requesting a power-down, many 32 kHz cycles before the
// arm toggle can arrive, so it is stable when sampled.
module wake_timer (
  input  logic        clk_sys,
  input  logic        rst_sys_n,
  input  logic        clk_32k,
  input  logic        rst_32k_n,
  input  logic        arm,
  input  logic [23:0] period,
  output logic        ev
);
  // ---------------- clk_sys side
  logic arm_tgl;
  always_ff @(posedge clk_sys or negedge rst_sys_n)
    if (!rst_sys_n) arm_tgl <= 1'b0; else if (arm) arm_tgl <= ~arm_tgl;

  logic match_tgl;
  pulse_sync u_ev_sync (.clk(clk_sys), .rst_n(rst_sys_n), .tgl(match_tgl), .pulse(ev));

  // ---------------- clk_32k side
  logic        arm_s, arm_d, running;
  logic [23:0] cnt;
  sync_2ff u_arm_sync (.clk(clk_32k), .rst_n(rst_32k_n), .d(arm_tgl), .q(arm_s));

  always_ff @(posedge clk_32k or negedge rst_32k_n) begin
    if (!rst_32k_n) begin
      arm_d     <= 1'b0;
      running   <= 1'b0;
      cnt       <= '0;
      match_tgl <= 1'b0;
    end else begin
      arm_d <= arm_s;
      if (arm_s != arm_d) begin
        running <= (period != 24'd0);
        cnt     <= 24'd1;
      end else if (running) begin
        if (cnt >= period) begin
          running   <= 1'b0;
          match_tgl <= ~match_tgl;
        end else begin
          cnt <= cnt + 24'd1;
        end
      end
    end
  end
endmodule
