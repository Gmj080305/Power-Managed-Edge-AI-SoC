// tb_soc.sv - top of the class-based testbench.
//   +TEST=<name>   test class (see tb_pkg::create_test), default test_matmul_rand
//   +ITERS=<n>     iterations / jobs, default 20
//   seed           xsim: -sv_seed <n>; Verilator: +verilator+seed+<n>
`timescale 1ns/1ps
module tb_soc;
  import tb_pkg::*;

`ifdef MAC_N
  localparam int N = `MAC_N;
`else
  localparam int N = 4;
`endif
  localparam real CLK_NS  = 20.0;    // 50 MHz
  localparam real C32K_NS = 1000.0;  // time-compressed 32 kHz clock

  logic clk_in = 1'b0, clk_32k = 1'b0;
  always #(CLK_NS / 2)  clk_in  = ~clk_in;
  always #(C32K_NS / 2) clk_32k = ~clk_32k;

  wire clk_sys;
  soc_if vif (.clk_sys(clk_sys));

  // DUT and models connect to local nets; the interface mirrors them.
  // (Connecting ports straight to interface members trips some simulators.)
  wire         por_n      = vif.por_n;
  wire         gpio_wake  = vif.gpio_wake;
  wire         host_wake  = vif.host_wake;
  wire         host_en    = vif.host_en;
  wire         host_valid = vif.host_valid;
  wire  [31:0] host_addr  = vif.host_addr;
  wire  [31:0] host_wdata = vif.host_wdata;
  wire  [3:0]  host_wstrb = vif.host_wstrb;
  logic [31:0] host_rdata;
  logic        host_ready, uart_tx, cpu_trap, vsel_hi, vdd_ok;
  logic        sw_en_cmp, sw_ack_cmp, sw_en_mem, sw_ack_mem, uart_pass, uart_fail;
  int          vdd_mv, nchars;

  soc_top #(.MAC_N(N)) dut (
    .clk_in(clk_in), .clk_32k(clk_32k), .por_n(por_n), .test_en(1'b0),
    .gpio_wake(gpio_wake), .host_wake(host_wake),
    .host_en(host_en), .host_valid(host_valid), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_wstrb(host_wstrb),
    .host_rdata(host_rdata), .host_ready(host_ready),
    .uart_tx(uart_tx), .cpu_trap(cpu_trap),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok),
    .sw_en_cmp(sw_en_cmp), .sw_ack_cmp(sw_ack_cmp),
    .sw_en_mem(sw_en_mem), .sw_ack_mem(sw_ack_mem));

  assign clk_sys = dut.clk_sys;

  regulator_model  #(.SETTLE(20)) u_reg (.clk(clk_sys), .rst_n(por_n),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok), .vdd_mv(vdd_mv));
  pwr_switch_model #(.DELAY(8)) u_swc (.clk(clk_sys), .rst_n(por_n), .en(sw_en_cmp), .ack(sw_ack_cmp));
  pwr_switch_model #(.DELAY(8)) u_swm (.clk(clk_sys), .rst_n(por_n), .en(sw_en_mem), .ack(sw_ack_mem));
  uart_rx_model u_uart (.clk(clk_sys), .div(dut.u_mem.uart_div), .rx(uart_tx),
    .pass(uart_pass), .fail(uart_fail), .nchars(nchars));

  // Host responses are sampled mid-cycle, where the driver reads them.
  // (They depend combinationally on the host address; feeding them straight
  // back into the interface forms a loop some simulators will not settle.)
  always @(negedge clk_sys) begin
    vif.host_rdata <= host_rdata;
    vif.host_ready <= host_ready;
  end
  assign vif.uart_tx     = uart_tx;
  assign vif.cpu_trap    = cpu_trap;
  assign vif.vsel_hi     = vsel_hi;
  assign vif.vdd_ok      = vdd_ok;
  assign vif.sw_ack_cmp  = sw_ack_cmp;
  assign vif.sw_ack_mem  = sw_ack_mem;
  assign vif.uart_pass   = uart_pass;
  assign vif.uart_fail   = uart_fail;
  assign vif.pstate      = dut.u_aon.u_pmu.pstate;
  assign vif.pmu_busy    = dut.u_aon.u_pmu.busy;
  assign vif.freq_lo_ack = dut.u_aon.freq_lo_ack;
  assign vif.mac_clk_en  = dut.u_cmp.mac_clk_en;

  initial begin
    string    name;
    int       iters;
    base_test t;

    if (!$value$plusargs("TEST=%s", name)) name = "test_matmul_rand";
    if (!$value$plusargs("ITERS=%d", iters)) iters = 20;
`ifdef WAVES
    $dumpfile("tb_soc.vcd");
    $dumpvars(0, tb_soc);
`endif
    vif.por_n      = 1'b0;
    vif.gpio_wake  = 1'b0;
    vif.host_wake  = 1'b0;
    vif.host_en    = (name != "test_fw_e2e");   // host drives the bus, CPU in reset
    vif.host_valid = 1'b0;
    vif.host_addr  = '0;
    vif.host_wdata = '0;
    vif.host_wstrb = '0;
    #(3 * C32K_NS);                              // POR covers the slow clock too
    vif.por_n = 1'b1;
    repeat (10) @(negedge vif.clk_sys);

    $display("[%0t] TEST %s N=%0d ITERS=%0d", $time, name, N, iters);
    t = create_test(name, vif, N, iters);
    t.body();
    t.cov.report();
    $display("[%0t] %s: %0d checks, %0d errors", $time, name, t.sb.checks, t.sb.errors);
    if (t.sb.errors == 0 && t.sb.checks > 0) $display("TEST PASSED %s", name);
    else                                     $display("TEST FAILED %s", name);
    $finish;
  end

  // Global watchdog
  initial begin
    #(4_000_000_000.0);
    $display("TEST FAILED watchdog timeout");
    $finish;
  end
endmodule
