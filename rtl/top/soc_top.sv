// soc_top.sv - power-managed edge-AI SoC.
//
//   PD_AON (always on, 1.80 V)  : PMU, DVFS clocking, wake logic, retention
//                                 shadow, AON registers, pad-side isolation
//   PD_CMP (switched, DVFS)     : PicoRV32, boot ROM, INT8 MAC accelerator
//   PD_MEM (switched, 1.80 V)   : scratch RAM, UART
//
// The top level itself belongs to PD_AON (UPF: create_power_domain PD_AON
// -include_scope). Power switches and the voltage regulator are off-chip /
// modelled: the SoC drives sw_en_* and vsel_hi and reads back sw_ack_* and
// vdd_ok.
module soc_top #(
  parameter int MAC_N     = 4,
  parameter int RAM_WORDS = 128,
  parameter int ROM_WORDS = 1024
) (
  input  logic        clk_in,       // reference clock (OPP-H frequency)
  input  logic        clk_32k,      // 32.768 kHz always-on clock
  input  logic        por_n,        // power-on reset
  input  logic        test_en,      // clock-gate test override, tie low
  // wake pins
  input  logic        gpio_wake,
  input  logic        host_wake,
  // debug host port
  input  logic        host_en,
  input  logic        host_valid,
  input  logic [31:0] host_addr,
  input  logic [31:0] host_wdata,
  input  logic [3:0]  host_wstrb,
  output logic [31:0] host_rdata,
  output logic        host_ready,
  // serial console
  output logic        uart_tx,
  output logic        cpu_trap,
  // power delivery interface
  output logic        vsel_hi,
  input  logic        vdd_ok,
  output logic        sw_en_cmp,
  input  logic        sw_ack_cmp,
  output logic        sw_en_mem,
  input  logic        sw_ack_mem
);
  logic clk_sys, clk_cmp, clk_mem, rst_cmp_n, rst_mem_n;
  logic cmp_iso, mem_iso;

  // PD_CMP <-> PD_MEM
  logic        c2m_valid;
  logic [31:0] c2m_addr, c2m_wdata, m2c_rdata;
  logic [3:0]  c2m_wstrb;
  logic        m2c_ready, mem_uart_tx;

  // PD_CMP <-> PD_AON
  logic        c2a_valid;
  logic [31:0] c2a_addr, c2a_wdata, a2c_rdata;
  logic [3:0]  c2a_wstrb;
  logic        a2c_ready;
  logic        pwr_req, pwr_ack_raw, restore, trap_raw, mac_clk_en;
  logic [8:0]  ret_cfg_raw, ret_cfg_shadow;
  logic [31:0] host_rdata_raw;
  logic        host_ready_raw;

  aon_top u_aon (
    .clk_in(clk_in), .clk_32k(clk_32k), .por_n(por_n), .test_en(test_en),
    .gpio_wake(gpio_wake), .host_wake(host_wake),
    .clk_sys(clk_sys), .clk_cmp(clk_cmp), .clk_mem(clk_mem),
    .rst_cmp_n(rst_cmp_n), .rst_mem_n(rst_mem_n),
    .cmp_valid(c2a_valid), .cmp_addr(c2a_addr), .cmp_wdata(c2a_wdata),
    .cmp_wstrb(c2a_wstrb), .cmp_rdata(a2c_rdata), .cmp_ready(a2c_ready),
    .cmp_pwr_ack_raw(pwr_ack_raw), .ret_cfg_raw(ret_cfg_raw), .cmp_trap_raw(trap_raw),
    .cmp_pwr_req(pwr_req), .cmp_restore(restore), .ret_cfg_shadow(ret_cfg_shadow),
    .cmp_iso(cmp_iso), .mem_iso(mem_iso), .cmp_trap(cpu_trap),
    .vsel_hi(vsel_hi), .vdd_ok(vdd_ok),
    .sw_en_cmp(sw_en_cmp), .sw_ack_cmp(sw_ack_cmp),
    .sw_en_mem(sw_en_mem), .sw_ack_mem(sw_ack_mem));

  cmp_top #(.N(MAC_N), .ROM_WORDS(ROM_WORDS)) u_cmp (
    .clk(clk_cmp), .rst_n(rst_cmp_n), .pwr_good(sw_ack_cmp), .test_en(test_en),
    .host_en(host_en), .host_valid(host_valid), .host_addr(host_addr),
    .host_wdata(host_wdata), .host_wstrb(host_wstrb),
    .host_rdata(host_rdata_raw), .host_ready(host_ready_raw),
    .mem_valid(c2m_valid), .mem_addr(c2m_addr), .mem_wdata(c2m_wdata),
    .mem_wstrb(c2m_wstrb), .mem_rdata(m2c_rdata), .mem_ready(m2c_ready),
    .mem_iso(mem_iso),
    .aon_valid(c2a_valid), .aon_addr(c2a_addr), .aon_wdata(c2a_wdata),
    .aon_wstrb(c2a_wstrb), .aon_rdata(a2c_rdata), .aon_ready(a2c_ready),
    .pwr_req(pwr_req), .pwr_ack(pwr_ack_raw), .ret_cfg_q(ret_cfg_raw),
    .restore(restore), .ret_cfg_d(ret_cfg_shadow), .trap(trap_raw),
    .mac_clk_en(mac_clk_en));

  mem_top #(.RAM_WORDS(RAM_WORDS)) u_mem (
    .clk(clk_mem), .rst_n(rst_mem_n), .pwr_good(sw_ack_mem), .cmp_iso(cmp_iso),
    .valid(c2m_valid), .addr(c2m_addr), .wdata(c2m_wdata), .wstrb(c2m_wstrb),
    .rdata(m2c_rdata), .ready(m2c_ready), .uart_tx(mem_uart_tx));

  // Pad-side isolation (PD_AON): an off PD_MEM must not drive the UART pin;
  // clamp to 1, the idle level. The host-port read path comes from PD_CMP.
  iso_clamp1 #(.W(1))  u_iso_uart (.iso(mem_iso), .d(mem_uart_tx), .q(uart_tx));
  logic [32:0] host_rx_ls;
  ls_lh      #(.W(33)) u_ls_host  (.d({host_ready_raw, host_rdata_raw}), .q(host_rx_ls));
  iso_clamp0 #(.W(33)) u_iso_host (.iso(cmp_iso), .d(host_rx_ls), .q({host_ready, host_rdata}));
endmodule
