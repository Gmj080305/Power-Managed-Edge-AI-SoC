// tb_pkg.sv - class-based verification environment for the SoC.
//
//   host_driver  - bus master on the debug host port (CPU held in reset)
//   mat_job      - constrained-random matrix job, golden model inside
//   pwr_req_item - constrained-random power request + wake stimulus
//   pmu_model    - predicts PMU behaviour (legal / illegal / end state)
//   scoreboard   - counts checks and errors
//   soc_cov      - functional coverage (covergroups; xsim/commercial only)
//   base_test + one class per test, chosen with +TEST=<name>
//
// Constraints are honoured by xsim and commercial simulators. Verilator
// 5.0x ignores constraints, so under VERILATOR each class maps its random
// values into the same legal space in fixup() (called from post_randomize)
// and `RANDOMIZE still checks legal(): one legal space either way.
`timescale 1ns/1ps
package tb_pkg;

  // ---------------------------------------------------------------- defs
  localparam bit [31:0] ACC  = 32'h2000_0000;
  localparam bit [31:0] AON  = 32'h3000_0000;
  localparam bit [31:0] RAM  = 32'h1000_0000;
  localparam bit [1:0]  PS_ACTIVE_H = 2'd0, PS_ACTIVE_L = 2'd1, PS_IDLE = 2'd2, PS_SLEEP = 2'd3;
  localparam int        WK_TIMER = 0, WK_GPIO = 1, WK_HOST = 2;

  function automatic string ps_name(bit [1:0] p);
    case (p)
      PS_ACTIVE_H: return "ACTIVE_H";
      PS_ACTIVE_L: return "ACTIVE_L";
      PS_IDLE:     return "IDLE";
      default:     return "SLEEP";
    endcase
  endfunction

  `define RANDOMIZE(obj) \
    begin \
      if (!obj.randomize()) $fatal(1, "randomize failed in %m"); \
      if (!obj.legal())     $fatal(1, "randomized object outside its legal space in %m"); \
    end

  // ---------------------------------------------------------------- scoreboard
  class scoreboard;
    int checks;
    int errors;
    function void check(bit ok, string what);
      checks++;
      if (!ok) begin
        errors++;
        $display("[%0t] ERROR %s", $time, what);
      end
    endfunction
  endclass

  // ---------------------------------------------------------------- driver
  class host_driver;
    virtual soc_if vif;
    function new(virtual soc_if vif);
      this.vif = vif;
    endfunction

    task cycles(int n);
      repeat (n) @(negedge vif.clk_sys);
    endtask

    task write32(bit [31:0] addr, bit [31:0] data);
      @(negedge vif.clk_sys);
      vif.host_valid = 1'b1;
      vif.host_addr  = addr;
      vif.host_wdata = data;
      vif.host_wstrb = 4'hF;
      do @(negedge vif.clk_sys); while (!vif.host_ready);
      vif.host_valid = 1'b0;
      vif.host_wstrb = 4'h0;
    endtask

    task read32(bit [31:0] addr, output bit [31:0] data);
      @(negedge vif.clk_sys);
      vif.host_valid = 1'b1;
      vif.host_addr  = addr;
      vif.host_wstrb = 4'h0;
      do @(negedge vif.clk_sys); while (!vif.host_ready);
      data = vif.host_rdata;
      vif.host_valid = 1'b0;
    endtask

    task pulse(bit gpio);
      @(negedge vif.clk_sys);
      if (gpio) vif.gpio_wake = 1'b1; else vif.host_wake = 1'b1;
      cycles(4);
      vif.gpio_wake = 1'b0;
      vif.host_wake = 1'b0;
    endtask

    task wait_stable(bit [1:0] want, int timeout = 20000);
      int n = 0;
      while (!(vif.pstate == want && !vif.pmu_busy) && n < timeout) begin
        @(negedge vif.clk_sys);
        n++;
      end
      if (n >= timeout) $fatal(1, "timeout waiting for %s", ps_name(want));
    endtask
  endclass

  // ---------------------------------------------------------------- MAC job
  class mat_job;
    int n;
    rand bit [3:0]    k;
    rand bit          relu;
    rand bit          corners;     // bias operands to -128 / -1 / 0 / 1 / 127
    rand int unsigned seed;
    byte              a [64];      // A[i][k] at i*n+k (row stride n)
    byte              b [64];
    int               c [64];      // expected result

    constraint c_k   { k inside {[1:8]}; k <= n; }
    constraint c_mix { corners dist {1 := 1, 0 := 3}; }

    function new(int n);
      this.n = n;
    endfunction

    function bit legal();
      return (k >= 1) && (k <= n);
    endfunction

    function void fixup();   // only used where constraints are not solved
      k       = 4'(1 + (k % n));
      corners = ($urandom % 4 == 0);
    endfunction

    // Operands come from a seeded generator so a failing job can be
    // reproduced from (seed, k, relu, corners) alone.
    function void post_randomize();
      int unsigned x;
      byte cv [5] = '{-128, -1, 0, 1, 127};
`ifdef VERILATOR
      fixup();
`endif
      x = seed | 1;
      for (int i = 0; i < n * n; i++) begin
        x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
        a[i] = (corners && x[3:0] < 6) ? cv[x[7:4] % 5] : byte'(x[15:8]);
        x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
        b[i] = (corners && x[3:0] < 6) ? cv[x[7:4] % 5] : byte'(x[15:8]);
      end
      for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) begin
          int s = 0;
          for (int kk = 0; kk < int'(k); kk++) s += int'(a[i*n+kk]) * int'(b[kk*n+j]);
          c[i*n+j] = (relu && s < 0) ? 0 : s;
        end
    endfunction

    function string sprint();
      return $sformatf("job k=%0d relu=%0d corners=%0d seed=%08h", k, relu, corners, seed);
    endfunction
  endclass

  // ---------------------------------------------------------------- power request
  class pwr_req_item;
    rand bit [2:0]  target;       // 0..3 legal codes, 4..7 illegal
    rand bit [2:0]  wake_src;     // one-hot: timer / gpio / host
    rand bit [2:0]  extra_mask;   // other sources also enabled
    rand int        wake_delay;   // cycles after the request (race tests)
    rand bit [3:0]  timer_ticks;
    rand bit        inject_illegal;

    constraint c_legal  { inject_illegal == 0 -> target inside {[0:3]}; }
    constraint c_onehot { wake_src inside {3'b001, 3'b010, 3'b100}; }
    constraint c_delay  { wake_delay inside {[0:120]}; }
    constraint c_ticks  { timer_ticks inside {[1:4]}; }
    constraint c_ill    { inject_illegal dist {0 := 9, 1 := 1}; }

    function bit legal();
      return (inject_illegal || target <= 3) &&
             (wake_src == 3'b001 || wake_src == 3'b010 || wake_src == 3'b100) &&
             (wake_delay >= 0 && wake_delay <= 120) && (timer_ticks >= 1 && timer_ticks <= 4);
    endfunction

    function void fixup();   // only used where constraints are not solved
      bit [1:0] w = 2'($urandom % 3);
      inject_illegal = ($urandom % 10 == 0);
      if (!inject_illegal) target = target % 4;
      wake_src    = 3'b001 << w;
      wake_delay  = int'($unsigned(wake_delay) % 121);
      timer_ticks = 4'(1 + timer_ticks % 4);
    endfunction

    function void post_randomize();
`ifdef VERILATOR
      fixup();
`endif
    endfunction

    function bit [2:0] mask();
      return wake_src | extra_mask;
    endfunction
  endclass

  // ---------------------------------------------------------------- PMU model
  class pmu_model;
    bit [1:0] state = PS_ACTIVE_H;
    bit [1:0] opp   = PS_ACTIVE_H;

    // Returns 1 if the PMU must accept the request.
    function bit accepts(bit [2:0] target, bit [2:0] mask);
      if (state > PS_ACTIVE_L)                 return 0;
      if (target > 3)                          return 0;
      if (target[1:0] == state)                return 0;   // legal no-op
      if (target >= PS_IDLE && mask == 3'b000) return 0;
      return 1;
    endfunction
    function bit flags_error(bit [2:0] target, bit [2:0] mask);
      return !accepts(target, mask) && !(target <= 3 && target[1:0] == state);
    endfunction
    function void apply(bit [2:0] target);
      state = target[1:0];
      if (target <= PS_ACTIVE_L) opp = target[1:0];
    endfunction
    function void woke();
      state = opp;
    endfunction
  endclass

  // ---------------------------------------------------------------- coverage
  class soc_cov;
`ifndef VERILATOR
    bit [1:0] from_s, to_s;
    bit [2:0] wsrc;
    int       wdelay;
    bit [3:0] k;
    bit       relu, corners, opp_l;

    // Transition coverage: one bin per legal (from, to) pair.
    covergroup cg_trans;
      cp_tr : coverpoint {from_s, to_s} {
        bins h_to_l     = {4'b00_01};
        bins l_to_h     = {4'b01_00};
        bins h_to_idle  = {4'b00_10};
        bins l_to_idle  = {4'b01_10};
        bins h_to_sleep = {4'b00_11};
        bins l_to_sleep = {4'b01_11};
        bins idle_to_h  = {4'b10_00};
        bins idle_to_l  = {4'b10_01};
        bins sleep_to_h = {4'b11_00};
        bins sleep_to_l = {4'b11_01};
      }
    endgroup

    covergroup cg_wake;
      cp_src   : coverpoint wsrc { bins timer = {3'b001}; bins gpio = {3'b010}; bins host = {3'b100}; }
      cp_from  : coverpoint from_s { bins idle = {2'd2}; bins sleep = {2'd3}; }
      cp_delay : coverpoint wdelay { bins early = {[0:10]}; bins mid = {[11:40]}; bins late = {[41:120]}; }
      x_src_from : cross cp_src, cp_from;
    endgroup

    // K bins follow the array size so 100 % is reachable for any N.
    covergroup cg_job (int n);
      cp_k       : coverpoint k { bins kv[] = {[1:n]}; }
      cp_relu    : coverpoint relu;
      cp_corners : coverpoint corners;
      cp_opp     : coverpoint opp_l;
      x_k_relu   : cross cp_k, cp_relu;
    endgroup

    function new(int n);
      cg_trans = new();
      cg_wake  = new();
      cg_job   = new(n);
    endfunction
`else
    function new(int n);
    endfunction
`endif

    function void s_trans(bit [1:0] f, bit [1:0] t);
`ifndef VERILATOR
      from_s = f; to_s = t; cg_trans.sample();
`endif
    endfunction
    function void s_wake(bit [2:0] src, bit [1:0] f, int d);
`ifndef VERILATOR
      wsrc = src; from_s = f; wdelay = d; cg_wake.sample();
`endif
    endfunction
    function void s_job(mat_job j, bit l);
`ifndef VERILATOR
      k = j.k; relu = j.relu; corners = j.corners; opp_l = l; cg_job.sample();
`endif
    endfunction
    function void report();
`ifndef VERILATOR
      $display("COVERAGE trans=%0.1f%% wake=%0.1f%% job=%0.1f%%",
               cg_trans.get_coverage(), cg_wake.get_coverage(), cg_job.get_coverage());
`else
      $display("COVERAGE functional coverage not collected (simulator lacks covergroups)");
`endif
    endfunction
  endclass

  // ---------------------------------------------------------------- base test
  class base_test;
    virtual soc_if vif;
    host_driver drv;
    scoreboard  sb;
    pmu_model   pm;
    soc_cov     cov;
    int         n;
    int         iters;

    function new(virtual soc_if vif, int n, int iters);
      this.vif   = vif;
      this.n     = n;
      this.iters = iters;
      drv = new(vif);
      sb  = new();
      pm  = new();
      cov = new(n);
    endfunction

    virtual task body();
    endtask

    // ---- helpers shared by tests
    task run_job(mat_job j);
      bit [31:0] w, st, cyc;
      int nw = (n * n + 3) / 4;
      for (int i = 0; i < nw; i++) begin
        w = 0;
        for (int l = 0; l < 4; l++) if (4*i+l < n*n) w[8*l +: 8] = j.a[4*i+l];
        drv.write32(ACC + 32'h100 + 4*i, w);
        w = 0;
        for (int l = 0; l < 4; l++) if (4*i+l < n*n) w[8*l +: 8] = j.b[4*i+l];
        drv.write32(ACC + 32'h200 + 4*i, w);
      end
      drv.write32(ACC + 32'h008, {23'h0, j.relu, 4'h0, j.k});
      drv.write32(ACC + 32'h000, 32'h1);
      do drv.read32(ACC + 32'h004, st); while (!st[1]);
      for (int p = 0; p < n * n; p++) begin
        drv.read32(ACC + 32'h400 + 4*p, w);
        sb.check(int'(w) == j.c[p], $sformatf("%s C[%0d]=%0d expected %0d", j.sprint(), p, int'(w), j.c[p]));
      end
      drv.read32(ACC + 32'h00C, cyc);
      sb.check(cyc == 32'(int'(j.k) + 2*n + 1), $sformatf("%s cycles=%0d expected %0d", j.sprint(), cyc, int'(j.k) + 2*n + 1));
      cov.s_job(j, vif.pstate == PS_ACTIVE_L);
    endtask

    task request(bit [2:0] target, bit [2:0] mask, output bit accepted);
      bit [31:0] st;
      bit expect_err = pm.flags_error(target, mask);
      accepted = pm.accepts(target, mask);
      drv.write32(AON + 32'h0C, {29'h0, mask});
      drv.write32(AON + 32'h04, 32'h0);              // clear err
      drv.write32(AON + 32'h00, {29'h0, target});
      if (!accepted) begin
        drv.read32(AON + 32'h04, st);
        sb.check(st[3] == expect_err, $sformatf("request %0d mask %b: err=%0b expected %0b", target, mask, st[3], expect_err));
        sb.check(st[1:0] == pm.state, $sformatf("refused request changed state to %s", ps_name(st[1:0])));
      end
    endtask

    task dvfs(bit [1:0] target);
      bit acc;
      bit [1:0] from = pm.state;
      request({1'b0, target}, 3'b001, acc);
      if (acc) begin
        drv.wait_stable(target);
        pm.apply({1'b0, target});
        cov.s_trans(from, target);
        sb.check(vif.freq_lo_ack == (target == PS_ACTIVE_L), "clock does not match OPP");
        sb.check(vif.vsel_hi == (target == PS_ACTIVE_H), "voltage does not match OPP");
      end
    endtask

    // Power down to IDLE/SLEEP, wake through `it`, check retention.
    task sleep_wake(pwr_req_item it, bit race);
      bit acc;
      bit [31:0] cfg, scr, ram, rd, br, wc0, wc1;
      bit [1:0] tgt = (it.target[0]) ? PS_SLEEP : PS_IDLE;
      bit [1:0] from = pm.state;
      cfg = {23'h0, 1'($urandom), 4'h0, 4'(1 + $urandom % n)};
      scr = $urandom;
      ram = $urandom;
      drv.write32(ACC + 32'h008, cfg);
      drv.write32(AON + 32'h24, scr);
      drv.write32(RAM + 32'h40, ram);
      drv.read32(AON + 32'h18, wc0);
      drv.write32(AON + 32'h08, {28'h0, it.timer_ticks});
      request({1'b0, tgt}, it.mask(), acc);
      if (!acc) begin
        sb.check(0, "legal power-down refused");
        return;
      end
      pm.apply({1'b0, tgt});
      cov.s_trans(from, tgt);
      if (race) begin
        drv.cycles(it.wake_delay);
        if (!it.wake_src[WK_TIMER]) drv.pulse(it.wake_src[WK_GPIO]);
      end else begin
        drv.wait_stable(tgt);
        if (!it.wake_src[WK_TIMER]) begin
          drv.cycles(it.wake_delay);
          drv.pulse(it.wake_src[WK_GPIO]);
        end
      end
      pm.woke();
      drv.wait_stable(pm.state, 200000);
      cov.s_trans(tgt, pm.state);
      cov.s_wake(it.wake_src, tgt, it.wake_delay);
      // retention checks
      drv.read32(ACC + 32'h008, rd);
      sb.check(rd == cfg, $sformatf("accelerator config not restored: %h expected %h", rd, cfg));
      drv.read32(AON + 32'h24, rd);
      sb.check(rd == scr, "AON scratch lost");
      drv.read32(AON + 32'h18, wc1);
      sb.check(wc1 == wc0 + 1, $sformatf("wake count %0d expected %0d", wc1, wc0 + 1));
      drv.read32(AON + 32'h14, br);
      sb.check(br[0] && br[2:1] == tgt, $sformatf("BOOT_REASON %h does not record a wake from %s", br, ps_name(tgt)));
      sb.check(br[6:4] != 3'b000 && (br[6:4] & ~it.mask()) == 3'b000,
               $sformatf("BOOT_REASON source %b not within enabled mask %b", br[6:4], it.mask()));
      if (tgt == PS_IDLE) begin
        drv.read32(RAM + 32'h40, rd);
        sb.check(rd == ram, "RAM changed across IDLE (PD_MEM should stay on)");
      end
    endtask
  endclass

  // ---------------------------------------------------------------- tests
  class test_matmul_rand extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      for (int i = 0; i < iters; i++) begin
        mat_job j = new(n);
        `RANDOMIZE(j)
        if ($urandom % 4 == 0) dvfs(pm.state == PS_ACTIVE_H ? PS_ACTIVE_L : PS_ACTIVE_H);
        run_job(j);
      end
    endtask
  endclass

  class test_state_walk extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      // every legal transition at least once, in a fixed then random order
      bit [1:0] seq [$] = '{PS_ACTIVE_L, PS_IDLE, PS_ACTIVE_H, PS_IDLE, PS_ACTIVE_L,
                            PS_SLEEP, PS_ACTIVE_H, PS_SLEEP};
      for (int i = 0; i < iters; i++) seq.push_back(2'($urandom));
      foreach (seq[i]) begin
        if (seq[i] <= PS_ACTIVE_L) dvfs(seq[i]);
        else begin
          pwr_req_item it = new();
          `RANDOMIZE(it)
          it.target = {2'b0, seq[i] == PS_SLEEP};
          sleep_wake(it, 0);
        end
      end
    endtask
  endclass

  class test_sleep_wake_rand extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      for (int i = 0; i < iters; i++) begin
        pwr_req_item it = new();
        `RANDOMIZE(it)
        if ($urandom % 3 == 0) dvfs(pm.state == PS_ACTIVE_H ? PS_ACTIVE_L : PS_ACTIVE_H);
        sleep_wake(it, 0);
      end
    endtask
  endclass

  class test_wake_race extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      // Wake arrives at every point of the power-down sequence.
      for (int i = 0; i < iters; i++) begin
        pwr_req_item it = new();
        `RANDOMIZE(it)
        it.wake_delay = i % 121;                  // sweep, not just random
        if (it.wake_src[WK_TIMER]) it.wake_src = 3'b010;
        sleep_wake(it, 1);
      end
    endtask
  endclass

  class test_dvfs_switch extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      for (int i = 0; i < iters; i++) begin
        mat_job j = new(n);
        dvfs(pm.state == PS_ACTIVE_H ? PS_ACTIVE_L : PS_ACTIVE_H);
        `RANDOMIZE(j)
        run_job(j);
      end
    endtask
  endclass

  class test_illegal_req extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      bit acc;
      for (int i = 0; i < iters; i++) begin
        bit [2:0] t = 3'($urandom);
        bit [2:0] m = (i % 2) ? 3'b000 : 3'($urandom);
        if (pm.accepts(t, m) && t <= PS_ACTIVE_L) begin
          dvfs(t[1:0]);
        end else if (!pm.accepts(t, m)) begin
          request(t, m, acc);
        end
      end
    endtask
  endclass

  class test_fw_e2e extends base_test;
    function new(virtual soc_if vif, int n, int iters); super.new(vif, n, iters); endfunction
    task body();
      int t = 0;
      // TB only provides the GPIO wake the firmware waits for in SLEEP.
      while (!vif.uart_pass && !vif.uart_fail && !vif.cpu_trap && t < 3_000_000) begin
        if (vif.pstate == PS_SLEEP && !vif.pmu_busy) begin
          drv.cycles(50);
          drv.pulse(1);
        end
        @(negedge vif.clk_sys);
        t++;
      end
      sb.check(vif.uart_pass && !vif.uart_fail, "firmware did not report PASS");
      sb.check(!vif.cpu_trap, "CPU trapped");
    endtask
  endclass

  // ---------------------------------------------------------------- factory
  function automatic base_test create_test(string name, virtual soc_if vif, int n, int iters);
    case (name)
      "test_matmul_rand":     begin test_matmul_rand t = new(vif, n, iters);     return t; end
      "test_state_walk":      begin test_state_walk t = new(vif, n, iters);      return t; end
      "test_sleep_wake_rand": begin test_sleep_wake_rand t = new(vif, n, iters); return t; end
      "test_wake_race":       begin test_wake_race t = new(vif, n, iters);       return t; end
      "test_dvfs_switch":     begin test_dvfs_switch t = new(vif, n, iters);     return t; end
      "test_illegal_req":     begin test_illegal_req t = new(vif, n, iters);     return t; end
      "test_fw_e2e":          begin test_fw_e2e t = new(vif, n, iters);          return t; end
      default: $fatal(1, "unknown test %s", name);
    endcase
    return null;
  endfunction

endpackage
