// tb_gls.sv - power-aware gate-level simulation of the Sky130 netlist.
//
// The DUT is the Yosys netlist with real Sky130 isolation (lpflow_isobufsrc,
// lpflow_inputiso1p), level-shifter (lpflow_lsbuf_lh_isowell) and clock-gate
// (dlclkp) cells, with supply pins added by scripts/gls_power_pins.py and
// simulated with the SkyWater functional power models (USE_POWER_PINS,
// FUNCTIONAL). A cell whose VPWR is low drives X: nothing here is a modelling
// shortcut of ours, the power-off behaviour comes from the cell library.
//
// The rails follow the off-chip switches pessimistically: a domain is powered
// only while its switch is enabled AND acknowledged, so it loses power the
// moment the PMU opens the switch and regains it only once power-good is back.
//
// The debug host drives the bus (CPU held in reset) and walks:
//   job @ACTIVE_H -> IDLE -> GPIO wake -> retention checks -> job
//   -> ACTIVE_L -> SLEEP -> GPIO wake -> retention checks -> job @ACTIVE_L
// While PD_CMP is off it checks, every cycle, that the domain really is X
// inside, that every SoC output and AON-side value is known, and that the
// isolated outputs sit at their clamp value.
//
// Build with FAULT_NO_ISO (run.py gls --fault): the test must fail.
`timescale 1ns/1ps
`define HAS_X(v) (^(v) === 1'bx)
module tb_gls;
  localparam int  N      = 4;
  localparam real CLK_NS = 20.0;
  localparam real C32K   = 1000.0;   // time-compressed 32 kHz clock
  localparam bit [31:0] RAM = 32'h1000_0000, ACC = 32'h2000_0000, AON = 32'h3000_0000;

  logic clk_in = 1'b0, clk_32k = 1'b0;
  always #(CLK_NS / 2) clk_in  = ~clk_in;
  always #(C32K / 2)   clk_32k = ~clk_32k;

  logic        por_n = 1'b0, gpio_wake = 1'b0, host_wake = 1'b0;
  logic        host_valid = 1'b0;
  logic [31:0] host_addr = '0, host_wdata = '0;
  logic [3:0]  host_wstrb = '0;
  wire  [31:0] host_rdata;
  wire         host_ready, uart_tx, cpu_trap, vsel_hi, sw_en_cmp, sw_en_mem;
  logic        vdd_ok, sw_ack_cmp, sw_ack_mem;
  int          vdd_mv;

  // supply rails (1 = powered)
  wire VSS     = 1'b0;
  reg  VDD_AON = 1'b1;
  wire VDD_CMP = sw_en_cmp & sw_ack_cmp;
  wire VDD_MEM = sw_en_mem & sw_ack_mem;

  soc_top dut (
    .VDD_AON(VDD_AON), .VDD_CMP(VDD_CMP), .VDD_MEM(VDD_MEM), .VSS(VSS),
    .clk_in(clk_in), .clk_32k(clk_32k), .por_n(por_n), .test_en(1'b0),
    .gpio_wake(gpio_wake), .host_wake(host_wake),
    .host_en(1'b1), .host_valid(host_valid), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_wstrb(host_wstrb),
    .host_rdata(host_rdata), .host_ready(host_ready),
    .uart_tx(uart_tx), .cpu_trap(cpu_trap),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok),
    .sw_en_cmp(sw_en_cmp), .sw_ack_cmp(sw_ack_cmp),
    .sw_en_mem(sw_en_mem), .sw_ack_mem(sw_ack_mem));

  wire clk_sys = dut.u_aon.clk_sys;

  regulator_model  #(.SETTLE(20)) u_reg (.clk(clk_sys), .rst_n(por_n),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok), .vdd_mv(vdd_mv));
  pwr_switch_model #(.DELAY(8)) u_swc (.clk(clk_sys), .rst_n(por_n), .en(sw_en_cmp), .ack(sw_ack_cmp));
  pwr_switch_model #(.DELAY(8)) u_swm (.clk(clk_sys), .rst_n(por_n), .en(sw_en_mem), .ack(sw_ack_mem));

  int checks = 0, errors = 0;
  task automatic check(bit ok, string what);
    checks++;
    if (!ok) begin
      errors++;
      if (errors <= 20) $display("[%0t] ERROR %s", $time, what);
      if (errors >= 200) begin
        $display("tb_gls: stopping after %0d errors (%0d checks)", errors, checks);
        $display("TEST FAILED tb_gls");
        $finish;
      end
    end
  endtask

  // ------------------------------------------------------------ host port
  task automatic cycles(int n);
    repeat (n) @(negedge clk_sys);
  endtask

  task automatic xfer(bit wr, bit [31:0] addr, bit [31:0] wdata, output logic [31:0] rdata);
    int n = 0;
    @(negedge clk_sys);
    host_valid = 1'b1;
    host_addr  = addr;
    host_wdata = wdata;
    host_wstrb = wr ? 4'hF : 4'h0;
    do begin
      @(negedge clk_sys);
      n++;
    end while (host_ready !== 1'b1 && n < 2000);
    rdata = host_rdata;
    host_valid = 1'b0;
    host_wstrb = 4'h0;
    check(n < 2000, $sformatf("bus timeout at %h (ready=%b)", addr, host_ready));
  endtask

  task automatic wr32(bit [31:0] addr, bit [31:0] data);
    logic [31:0] unused;
    xfer(1'b1, addr, data, unused);
  endtask

  task automatic rd32(bit [31:0] addr, output logic [31:0] data);
    xfer(1'b0, addr, '0, data);
  endtask

  // ------------------------------------------------------------ MAC job
  task automatic run_job(int seed, bit [3:0] k, bit relu, string tag);
    byte a [16], b [16];
    int  c [16];
    int unsigned x = seed | 1;
    logic [31:0] w, st, cyc;
    int n_wait = 0;
    for (int i = 0; i < 16; i++) begin
      x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
      a[i] = byte'(x[15:8]);
      x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5);
      b[i] = byte'(x[15:8]);
    end
    a[0] = -128; b[0] = -128; a[5] = 127; b[5] = -1;   // corner operands
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        int s = 0;
        for (int kk = 0; kk < int'(k); kk++) s += int'(a[i*N+kk]) * int'(b[kk*N+j]);
        c[i*N+j] = (relu && s < 0) ? 0 : s;
      end
    for (int i = 0; i < 4; i++) begin
      wr32(ACC + 32'h100 + 4*i, {b2u(a[4*i+3]), b2u(a[4*i+2]), b2u(a[4*i+1]), b2u(a[4*i])});
      wr32(ACC + 32'h200 + 4*i, {b2u(b[4*i+3]), b2u(b[4*i+2]), b2u(b[4*i+1]), b2u(b[4*i])});
    end
    wr32(ACC + 32'h008, {23'h0, relu, 4'h0, k});
    wr32(ACC + 32'h000, 32'h1);
    do begin
      rd32(ACC + 32'h004, st);
      n_wait++;
    end while (st[1] !== 1'b1 && n_wait < 200);
    check(n_wait < 200, {tag, ": accelerator never finished"});
    for (int p = 0; p < 16; p++) begin
      rd32(ACC + 32'h400 + 4*p, w);
      check(w === c[p], $sformatf("%s: C[%0d] = %h expected %h", tag, p, w, c[p]));
    end
    rd32(ACC + 32'h00C, cyc);
    check(cyc === 32'(int'(k) + 2*N + 1), $sformatf("%s: cycles = %0d", tag, cyc));
    $display("[%0t] %s: K=%0d relu=%0d checked", $time, tag, k, relu);
  endtask

  function automatic logic [7:0] b2u(byte v);
    return v;
  endfunction

  // ------------------------------------------------------------ PMU
  task automatic wait_state(bit [1:0] want, string tag);
    logic [31:0] st;
    int n = 0;
    do begin
      rd32(AON + 32'h04, st);
      n++;
    end while (!(st[1:0] === want && st[2] === 1'b0) && n < 500);
    check(n < 500, $sformatf("%s: PMU never settled in state %0d (status %h)", tag, want, st));
  endtask

  task automatic dvfs(bit [1:0] target);
    wr32(AON + 32'h0C, 32'h1);
    wr32(AON + 32'h00, {30'h0, target});
    wait_state(target, "dvfs");
    check(vsel_hi === (target == 2'd0), "voltage does not match OPP");
  endtask

  // Monitor: active while PD_CMP has no supply.
  bit  watching = 0;
  int  off_cycles = 0, cmp_x_cycles = 0, mem_x_cycles = 0, mem_off_cycles = 0;
  always @(negedge clk_in) if (watching && VDD_CMP === 1'b0) begin
    off_cycles++;
    // the switched-off domain really is unknown inside (library power models)
    if (`HAS_X({dut.u_cmp.host_rdata, dut.u_cmp.aon_valid, dut.u_cmp.pwr_ack})) cmp_x_cycles++;
    // ... yet nothing outside it sees an X
    check(!`HAS_X({host_rdata, host_ready, uart_tx, cpu_trap, vsel_hi, sw_en_cmp, sw_en_mem}),
          $sformatf("X on a SoC output while PD_CMP is off: rdata=%h ready=%b uart=%b trap=%b",
                    host_rdata, host_ready, uart_tx, cpu_trap));
    check(host_ready === 1'b0 && host_rdata === 32'h0, "host port not clamped to 0");
    check(!`HAS_X({dut.u_aon.cmp_iso, dut.u_aon.mem_iso, dut.u_aon.clk_cmp,
                   dut.u_aon.rst_cmp_n, dut.u_aon.cmp_restore}),
          "X on a PMU output while PD_CMP is off");
    check(dut.u_aon.cmp_iso === 1'b1, "PD_CMP unpowered but not isolated");
    if (VDD_MEM === 1'b0) begin
      mem_off_cycles++;
      if (`HAS_X(dut.u_mem.uart_tx)) mem_x_cycles++;
      check(uart_tx === 1'b1, "UART pin not clamped high while PD_MEM is off");
      check(dut.u_aon.mem_iso === 1'b1, "PD_MEM unpowered but not isolated");
    end
  end

  task automatic sleep_wake(bit [1:0] tgt, bit [1:0] back, string tag);
    logic [31:0] cfg, scr, ram, rd, wc0, wc1, br;
    cfg = {23'h0, 1'b1, 4'h0, 4'd3};
    scr = 32'hC0DE_0000 | tgt;
    ram = 32'h5A5A_0F0F ^ {30'h0, tgt};
    wr32(ACC + 32'h008, cfg);
    wr32(AON + 32'h24, scr);
    wr32(RAM + 32'h40, ram);
    rd32(AON + 32'h18, wc0);
    wr32(AON + 32'h0C, 32'b010);          // wake on GPIO
    wr32(AON + 32'h04, 32'h0);
    wr32(AON + 32'h00, {30'h0, tgt});
    // switched off?
    begin
      int n = 0;
      while (VDD_CMP !== 1'b0 && n < 2000) begin cycles(1); n++; end
      check(n < 2000, {tag, ": PD_CMP never powered off"});
    end
    cycles(300);                          // stay down for a while
    check(VDD_MEM === (tgt == 2'd2), {tag, ": PD_MEM supply wrong for the state"});
    @(negedge clk_sys) gpio_wake = 1'b1;
    cycles(4);
    gpio_wake = 1'b0;
    begin
      int n = 0;
      while (VDD_CMP !== 1'b1 && n < 2000) begin cycles(1); n++; end
      check(n < 2000, {tag, ": PD_CMP never powered back on"});
    end
    cycles(60);
    wait_state(back, tag);
    rd32(ACC + 32'h008, rd);
    check(rd === cfg, $sformatf("%s: accelerator config not restored: %h expected %h", tag, rd, cfg));
    rd32(AON + 32'h24, rd);
    check(rd === scr, $sformatf("%s: AON scratch %h expected %h", tag, rd, scr));
    rd32(AON + 32'h18, wc1);
    check(wc1 === wc0 + 1, $sformatf("%s: wake count %0d expected %0d", tag, wc1, wc0 + 1));
    rd32(AON + 32'h14, br);
    check(br[0] === 1'b1 && br[2:1] === tgt && br[6:4] === 3'b010,
          $sformatf("%s: BOOT_REASON %h", tag, br));
    rd32(RAM + 32'h40, rd);
    if (tgt == 2'd2) check(rd === ram, $sformatf("%s: RAM %h expected %h (PD_MEM stayed on)", tag, rd, ram));
    else             check(`HAS_X(rd), $sformatf("%s: RAM %h survived SLEEP - power model not live?", tag, rd));
    $display("[%0t] %s: power-down, wake and retention checked", $time, tag);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_gls.vcd");
      $dumpvars(1, tb_gls);
    end
    #(3 * C32K);
    por_n = 1'b1;
    cycles(20);
    watching = 1;
    run_job(32'h1234_5678, 4'd4, 1'b0, "job ACTIVE_H");
    sleep_wake(2'd2, 2'd0, "IDLE");
    run_job(32'h0BAD_F00D, 4'd4, 1'b1, "job after IDLE");
    dvfs(2'd1);
    sleep_wake(2'd3, 2'd1, "SLEEP");
    run_job(32'h7777_1111, 4'd3, 1'b0, "job ACTIVE_L after SLEEP");
    dvfs(2'd0);
    run_job(32'h2468_ACE1, 4'd4, 1'b0, "job ACTIVE_H");

    $display("PD_CMP off for %0d cycles, X inside on %0d; PD_MEM off for %0d, X inside on %0d",
             off_cycles, cmp_x_cycles, mem_off_cycles, mem_x_cycles);
    check(off_cycles > 0 && cmp_x_cycles == off_cycles, "PD_CMP was not X while unpowered");
    check(mem_off_cycles > 0 && mem_x_cycles == mem_off_cycles, "PD_MEM was not X while unpowered");
    $display("tb_gls: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("TEST PASSED tb_gls");
    else             $display("TEST FAILED tb_gls");
    $finish;
  end

  initial begin
    #(5_000_000.0);
    $display("TEST FAILED tb_gls watchdog");
    $finish;
  end
endmodule
