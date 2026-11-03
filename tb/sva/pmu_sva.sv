// pmu_sva.sv - concurrent assertions bound into pmu_fsm (same rules the
// formal proof covers, checked here on every simulated cycle).
`timescale 1ns/1ps
module pmu_sva (
  input logic       clk,
  input logic       rst_n,
  input logic       cmp_sw_en,
  input logic       cmp_sw_ack,
  input logic       cmp_iso,
  input logic       cmp_clk_en,
  input logic       cmp_rst_n,
  input logic       cmp_save,
  input logic       cmp_restore,
  input logic       cmp_restored,
  input logic       mem_sw_en,
  input logic       mem_sw_ack,
  input logic       mem_iso,
  input logic       freq_lo,
  input logic       freq_hi_ack,
  input logic       vsel_hi,
  input logic       vdd_ok,
  input logic       busy,
  input logic [1:0] pstate
);
  // Every property: sampled on the posedge clock edge, off while in reset.
`define CHK(prop) @(posedge clk) disable iff (!rst_n) (prop)

  a_cmp_off_iso : assert property (`CHK(!cmp_sw_en  |-> cmp_iso));
  a_mem_off_iso : assert property (`CHK(!mem_sw_en  |-> mem_iso));
  a_cmp_pg_iso  : assert property (`CHK(!cmp_sw_ack |-> cmp_iso));
  a_mem_pg_iso  : assert property (`CHK(!mem_sw_ack |-> mem_iso));
  a_no_illegal  : assert property (`CHK(cmp_sw_en |-> mem_sw_en));
  a_off_clk     : assert property (`CHK(!cmp_sw_en |-> !cmp_clk_en && !cmp_rst_n));
  a_save_ok     : assert property (`CHK(cmp_save |-> !cmp_clk_en && !cmp_iso && cmp_sw_ack));
  a_restore_ok  : assert property (`CHK(cmp_restore |-> cmp_sw_ack && cmp_clk_en && cmp_rst_n));
  a_iso_release : assert property (`CHK($fell(cmp_iso) |-> cmp_sw_ack && cmp_restored));
  a_fhi_vhi     : assert property (`CHK(freq_hi_ack |-> vsel_hi && vdd_ok));
  a_f_after_v   : assert property (`CHK($fell(freq_lo) |-> vsel_hi && vdd_ok));

`ifndef VERILATOR
  // Sequences with cycle delays (not supported by every simulator yet)
  c_sleep_wake  : cover property (`CHK(pstate == 2'd3 && !busy ##[1:$] pstate <= 2'd1 && !busy));
  c_idle_wake   : cover property (`CHK(pstate == 2'd2 && !busy ##[1:$] pstate <= 2'd1 && !busy));
  c_l_to_h      : cover property (`CHK(pstate == 2'd1 && !busy ##[1:$] pstate == 2'd0 && !busy));
  a_busy_ends   : assert property (`CHK($rose(busy) |-> ##[1:5000] !busy));
`endif
`undef CHK
endmodule

bind pmu_fsm pmu_sva u_pmu_sva (
  .clk(clk), .rst_n(rst_n),
  .cmp_sw_en(cmp_sw_en), .cmp_sw_ack(cmp_sw_ack), .cmp_iso(cmp_iso),
  .cmp_clk_en(cmp_clk_en), .cmp_rst_n(cmp_rst_n), .cmp_save(cmp_save),
  .cmp_restore(cmp_restore), .cmp_restored(cmp_restored),
  .mem_sw_en(mem_sw_en), .mem_sw_ack(mem_sw_ack), .mem_iso(mem_iso),
  .freq_lo(freq_lo), .freq_hi_ack(freq_hi_ack), .vsel_hi(vsel_hi), .vdd_ok(vdd_ok),
  .busy(busy), .pstate(pstate));
