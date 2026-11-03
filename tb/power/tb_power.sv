// tb_power.sv - firmware-driven, power-aware system test (no classes).
//
// Runs the real firmware through cold boot, DVFS, IDLE (timer wake) and
// SLEEP (GPIO wake) with +define+PWR_SIM, so powered-off domains drive X.
// Needs a 4-state simulator: Icarus (CI) or Vivado xsim.
//
// Checks
//   1. firmware prints "DONE PASS" before the timeout, no "FAIL", no trap
//   2. no X ever reaches a powered receiver (isolation works)
//   3. a powered-off domain really does drive X (the model is live)
//   4. scratch RAM survives IDLE and is lost in SLEEP
//   5. PMU outputs obey the sequencing rules on every cycle
`timescale 1ns/1ps
module tb_power;
  localparam real CLK_NS   = 20.0;    // 50 MHz clk_in
  localparam real C32K_NS  = 1000.0;  // time-compressed "32 kHz" clock (1 MHz)
  localparam int  TIMEOUT  = 2_000_000;

`ifdef MAC_N
  localparam int N = `MAC_N;
`else
  localparam int N = 4;
`endif

  logic clk_in = 1'b0, clk_32k = 1'b0, por_n = 1'b0;
  logic gpio_wake = 1'b0, host_wake = 1'b0;
  logic uart_tx, cpu_trap;
  logic vsel_hi, vdd_ok, sw_en_cmp, sw_ack_cmp, sw_en_mem, sw_ack_mem;
  logic [31:0] host_rdata;
  logic host_ready;
  int   vdd_mv;

  always #(CLK_NS / 2)  clk_in  = ~clk_in;
  always #(C32K_NS / 2) clk_32k = ~clk_32k;

  soc_top #(.MAC_N(N)) dut (
    .clk_in(clk_in), .clk_32k(clk_32k), .por_n(por_n), .test_en(1'b0),
    .gpio_wake(gpio_wake), .host_wake(host_wake),
    .host_en(1'b0), .host_valid(1'b0), .host_addr(32'h0), .host_wdata(32'h0),
    .host_wstrb(4'h0), .host_rdata(host_rdata), .host_ready(host_ready),
    .uart_tx(uart_tx), .cpu_trap(cpu_trap),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok),
    .sw_en_cmp(sw_en_cmp), .sw_ack_cmp(sw_ack_cmp),
    .sw_en_mem(sw_en_mem), .sw_ack_mem(sw_ack_mem));

  wire clk_sys = dut.clk_sys;

  regulator_model  #(.SETTLE(20)) u_reg  (.clk(clk_sys), .rst_n(por_n), .vsel_hi(vsel_hi),
                                          .vdd_ok(vdd_ok), .vdd_mv(vdd_mv));
  pwr_switch_model #(.DELAY(8))   u_swc  (.clk(clk_sys), .rst_n(por_n), .en(sw_en_cmp), .ack(sw_ack_cmp));
  pwr_switch_model #(.DELAY(8))   u_swm  (.clk(clk_sys), .rst_n(por_n), .en(sw_en_mem), .ack(sw_ack_mem));

  logic pass, fail;
  int   nchars;
  uart_rx_model u_uart (.clk(clk_sys), .div(dut.u_mem.uart_div), .rx(uart_tx),
                        .pass(pass), .fail(fail), .nchars(nchars));

  // ------------------------------------------------------------ stimulus
  int errors = 0;
  int cycles = 0;

  initial begin
`ifdef WAVES
    $dumpfile("tb_power.vcd");
    $dumpvars(0, tb_power);
`endif
`ifdef ACTIVITY
    // Switching activity for power analysis (VCD_FILE in ORFS): the DUT
    // only, over a window of firmware running the accelerator at OPP-H.
    // Scope for ORFS: POWER_FILE_SCOPE = tb_power/dut
    $dumpfile("activity.vcd");
    $dumpvars(0, dut);
    $dumpoff;
`endif
    // Hold power-on reset for 3 periods of the slow clock so the 32 kHz
    // domain's reset synchroniser sees it (as a real POR circuit ensures).
    #(3 * C32K_NS);
    por_n = 1'b1;
  end

  always @(posedge clk_sys) cycles++;

`ifdef ACTIVITY
  initial begin
    wait (u_uart.nchars > 0);           // console up: boot code finished
    $dumpon;
    repeat (20000) @(posedge clk_sys);  // 400 us at 50 MHz: matmul + checks
    $dumpoff;
    $display("[%0t] TB   | activity window dumped (20000 cycles)", $time);
  end
`endif

  // Wake from SLEEP with a GPIO pulse once the SoC is fully asleep.
  initial begin
    wait (dut.u_aon.u_pmu.pstate == soc_pkg::PS_SLEEP && !dut.u_aon.u_pmu.busy);
    repeat (50) @(posedge clk_sys);
    $display("[%0t] TB   | SLEEP reached, pulsing gpio_wake", $time);
    gpio_wake = 1'b1;
    repeat (4) @(posedge clk_sys);
    gpio_wake = 1'b0;
  end

  // ------------------------------------------------------------ checks
  // HAS_X: the reduction XOR of a vector is X if any bit is X. Used instead
  // of $isunknown, which some simulator versions mis-evaluate on
  // concatenations of hierarchical signals.
`define HAS_X(v) ((^(v)) === 1'bx)

  // 2. isolation. Control signals entering a powered domain are never X,
  //    and while isolation is on every isolated signal sits at its clamp
  //    value. (Read data may legitimately be X: never-written RAM.)
  // Sampled mid-cycle (falling edge) so they see settled values.
  always @(negedge clk_sys) if (dut.u_aon.rst_sys_n) begin
    // PD_CMP -> PD_AON : {valid, addr, wdata, wstrb, pwr_ack, ret_cfg, trap}
    if (`HAS_X({dut.u_aon.b_valid, dut.u_aon.pwr_ack, dut.u_aon.cmp_trap})) begin
      errors++; $display("[%0t] ERROR X on a control signal entering PD_AON: valid=%b ack=%b trap=%b", $time, dut.u_aon.b_valid, dut.u_aon.pwr_ack, dut.u_aon.cmp_trap);
    end
    if (dut.u_aon.cmp_iso && dut.u_aon.rx_iso !== '0) begin
      errors++; $display("[%0t] ERROR PD_AON inputs not clamped while PD_CMP isolated", $time);
    end
    // PD_CMP -> PD_MEM
    if (sw_ack_mem && `HAS_X(dut.u_mem.v)) begin
      errors++; $display("[%0t] ERROR X on valid entering PD_MEM", $time);
    end
    if (sw_ack_mem && dut.u_aon.cmp_iso && dut.u_mem.in_iso !== '0) begin
      errors++; $display("[%0t] ERROR PD_MEM inputs not clamped while PD_CMP isolated", $time);
    end
    // PD_MEM -> PD_CMP
    if (sw_ack_cmp && `HAS_X(dut.u_cmp.mem_rdy_i)) begin
      errors++; $display("[%0t] ERROR X on ready entering PD_CMP", $time);
    end
    if (sw_ack_cmp && dut.u_aon.mem_iso && {dut.u_cmp.mem_rdy_i, dut.u_cmp.mem_rdata_i} !== '0) begin
      errors++; $display("[%0t] ERROR PD_CMP inputs not clamped while PD_MEM isolated", $time);
    end
    // pins
    if (`HAS_X({uart_tx, host_ready, cpu_trap, vsel_hi, sw_en_cmp, sw_en_mem})) begin
      errors++; $display("[%0t] ERROR X on an SoC control pin: uart=%b hready=%b trap=%b vsel=%b swc=%b swm=%b", $time, uart_tx, host_ready, cpu_trap, vsel_hi, sw_en_cmp, sw_en_mem);
    end
  end

  // 3. the corruption model is live; 4. RAM retention
  int cmp_off_seen = 0, mem_off_seen = 0;
  logic [31:0] ram_snap [8];
  always @(posedge clk_sys) begin
    if (!sw_ack_cmp && `HAS_X(dut.u_cmp.mem_valid)) cmp_off_seen++;
    if (!sw_ack_mem && `HAS_X(dut.u_mem.u_ram.mem[0])) mem_off_seen++;
  end

  initial begin
    wait (dut.u_aon.u_pmu.pstate == soc_pkg::PS_IDLE && !dut.u_aon.u_pmu.busy);
    for (int i = 0; i < 8; i++) ram_snap[i] = dut.u_mem.u_ram.mem[i];
    wait (dut.u_aon.u_pmu.pstate != soc_pkg::PS_IDLE);
    for (int i = 0; i < 8; i++)
      if (dut.u_mem.u_ram.mem[i] !== ram_snap[i]) begin
        errors++; $display("[%0t] ERROR RAM word %0d changed across IDLE", $time, i);
      end
    $display("[%0t] TB   | IDLE left, RAM words intact", $time);
  end

  // 5. sequencing rules (same as the SVA / formal properties)
  always @(negedge clk_sys) if (dut.u_aon.rst_sys_n) begin
    if (!sw_en_cmp && !dut.u_aon.cmp_iso)              begin errors++; $display("[%0t] ERROR CMP off without isolation", $time); end
    if (!sw_en_mem && !dut.u_aon.mem_iso)              begin errors++; $display("[%0t] ERROR MEM off without isolation", $time); end
    if (sw_en_cmp && !sw_en_mem)                       begin errors++; $display("[%0t] ERROR CMP on while MEM off", $time); end
    if (dut.u_aon.freq_hi_ack && !(vsel_hi && vdd_ok)) begin errors++; $display("[%0t] ERROR full speed below 1.80 V", $time); end
  end

  // Wake latency: GPIO edge to first CPU bus request after wake
  realtime t_wake_ev;
  initial begin
    @(posedge gpio_wake);
    t_wake_ev = $realtime;
    @(posedge dut.u_aon.u_pmu.cmp_rst_n);
    @(posedge dut.u_cmp.cpu_valid);
    $display("[%0t] TB   | wake latency GPIO -> first CPU fetch: %0.1f ns", $time,
             $realtime - t_wake_ev);
  end

  // ------------------------------------------------------------ finish
  initial begin
    int t = 0;
    while (!(pass === 1'b1 || fail === 1'b1 || cpu_trap === 1'b1) && t < TIMEOUT) begin
      @(posedge clk_in);
      t++;
    end
    repeat (20) @(posedge clk_in);
    if (!pass)             begin errors++; $display("ERROR firmware did not report PASS"); end
    if (fail)              begin errors++; $display("ERROR firmware reported FAIL"); end
    if (cpu_trap)          begin errors++; $display("ERROR CPU trapped"); end
`ifdef PWR_SIM
    if (cmp_off_seen == 0) begin errors++; $display("ERROR never saw PD_CMP outputs go X while off"); end
    if (mem_off_seen == 0) begin errors++; $display("ERROR never saw PD_MEM RAM go X while off"); end
`endif
    $display("tb_power: N=%0d cycles=%0d wakes=%0d uart_chars=%0d",
             N, cycles, dut.u_aon.u_regs.wake_cnt, nchars);
    if (errors == 0) $display("TEST PASSED tb_power");
    else             $display("TEST FAILED tb_power errors=%0d", errors);
    $finish;
  end
endmodule
