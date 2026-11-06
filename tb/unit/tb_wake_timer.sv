// tb_wake_timer.sv - directed unit test of the wake timer CDC (Icarus or xsim).
// Case 2 is the stale-expiry race: re-arm while the previous expiry is still
// in the synchronisers. Before v0.2 that expiry was delivered (a spurious wake).
`timescale 1ns/1ps
module tb_wake_timer;
  logic clk_sys = 0, clk_32k = 0, rst_n = 0, arm = 0;
  logic [23:0] period = 24'd2;
  logic ev;
  int nev = 0;
  int errors = 0;
  always #10 clk_sys = ~clk_sys;
  always #500 clk_32k = ~clk_32k;
  wake_timer dut (.clk_sys(clk_sys), .rst_sys_n(rst_n), .clk_32k(clk_32k), .rst_32k_n(rst_n),
                  .arm(arm), .period(period), .ev(ev));
  always @(posedge clk_sys) if (ev) nev++;
  task automatic pulse_arm(); @(posedge clk_sys); arm <= 1; @(posedge clk_sys); arm <= 0; endtask
  initial begin
    #3000 rst_n = 1;
    // 1. normal: arm once, exactly one event
    pulse_arm(); #20000;
    if (nev != 1) begin errors++; $display("ERROR normal arm gave %0d events", nev); end
    // 2. stale: arm, wait until the expiry toggled in clk_32k but not yet
    //    synchronised, then re-arm with a long period: no event must appear
    nev = 0; period = 24'd2;
    pulse_arm();
    @(dut.match_tgl);                // expiry of this arming happened
    period = 24'd1000;               // next arming will not expire soon
    pulse_arm();                     // re-arm before the stale pulse lands
    #60000;
    if (nev != 0) begin errors++; $display("ERROR stale expiry delivered (%0d events)", nev); end
    else $display("stale expiry dropped");
    // 3. the new arming still expires
    #1000000;
    if (nev != 1) begin errors++; $display("ERROR re-armed timer gave %0d events", nev); end
    if (errors == 0) $display("TEST PASSED tb_wake_timer"); else $display("TEST FAILED tb_wake_timer"); $finish;
  end
endmodule
