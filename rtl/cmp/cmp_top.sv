// cmp_top.sv - PD_CMP: PicoRV32 + boot ROM + MAC accelerator + bus fabric.
//
// Bus masters: the CPU, or the debug host port when host_en = 1 (CPU held
// in reset). Slaves: ROM and accelerator are local; RAM/UART (PD_MEM) and the
// AON registers are remote and leave the domain through pd_out.
//
// Quiesce handshake with the PMU: when pwr_req rises, the fabric stops
// issuing new remote transactions once none is in flight (fence) and
// raises pwr_ack when the accelerator is idle too. Local ROM fetches may
// continue; the PMU then gates the clock and powers the domain down.
module cmp_top #(
  parameter int N         = 4,
  parameter int ROM_WORDS = 1024
) (
  input  logic        clk,          // gated clk_cmp
  input  logic        rst_n,        // domain reset from the PMU
  input  logic        pwr_good,     // power-switch acknowledge (sim only)
  input  logic        test_en,
  // debug host port (pins)
  input  logic        host_en,
  input  logic        host_valid,
  input  logic [31:0] host_addr,
  input  logic [31:0] host_wdata,
  input  logic [3:0]  host_wstrb,
  output logic [31:0] host_rdata,
  output logic        host_ready,
  // remote port to PD_MEM (RAM + UART)
  output logic        mem_valid,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [3:0]  mem_wstrb,
  input  logic [31:0] mem_rdata,    // from PD_MEM
  input  logic        mem_ready,
  input  logic        mem_iso,      // PD_MEM outputs isolated
  // remote port to PD_AON (PMU registers)
  output logic        aon_valid,
  output logic [31:0] aon_addr,
  output logic [31:0] aon_wdata,
  output logic [3:0]  aon_wstrb,
  input  logic [31:0] aon_rdata,
  input  logic        aon_ready,
  // power management
  input  logic        pwr_req,
  output logic        pwr_ack,
  output logic [8:0]  ret_cfg_q,    // retained accelerator config -> AON
  input  logic        restore,
  input  logic [8:0]  ret_cfg_d,
  output logic        trap,
  output logic        mac_clk_en
);

  // ------------------------------------------------------------ CPU
  logic        cpu_valid, cpu_instr, cpu_ready;
  logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
  logic [3:0]  cpu_wstrb;
  logic        cpu_trap;

  picorv32 #(
    .ENABLE_COUNTERS     (1'b1),
    .ENABLE_COUNTERS64   (1'b0),
    .ENABLE_REGS_DUALPORT(1'b1),
    .COMPRESSED_ISA      (1'b1),
    .ENABLE_MUL          (1'b1),
    .ENABLE_DIV          (1'b0),
    .ENABLE_IRQ          (1'b0),
    .CATCH_MISALIGN      (1'b1),
    .CATCH_ILLINSN       (1'b1),
    .PROGADDR_RESET      (32'h0000_0000)
  ) u_cpu (
    .clk       (clk),
    .resetn    (rst_n & ~host_en),
    .trap      (cpu_trap),
    .mem_valid (cpu_valid),
    .mem_instr (cpu_instr),
    .mem_ready (cpu_ready),
    .mem_addr  (cpu_addr),
    .mem_wdata (cpu_wdata),
    .mem_wstrb (cpu_wstrb),
    .mem_rdata (cpu_rdata),
    .mem_la_read (), .mem_la_write (), .mem_la_addr (),
    .mem_la_wdata (), .mem_la_wstrb (),
    .pcpi_valid (), .pcpi_insn (), .pcpi_rs1 (), .pcpi_rs2 (),
    .pcpi_wr (1'b0), .pcpi_rd (32'h0), .pcpi_wait (1'b0), .pcpi_ready (1'b0),
    .irq (32'h0), .eoi (),
    .trace_valid (), .trace_data ()
  );

  // ------------------------------------------------------------ master mux
  logic        m_valid, m_ready;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0]  m_wstrb;

  assign m_valid = host_en ? host_valid : cpu_valid;
  assign m_addr  = host_en ? host_addr  : cpu_addr;
  assign m_wdata = host_en ? host_wdata : cpu_wdata;
  assign m_wstrb = host_en ? host_wstrb : cpu_wstrb;

  assign cpu_ready  = ~host_en & m_ready;
  assign cpu_rdata  = m_rdata;
  assign host_ready = host_en & m_ready;
  assign host_rdata = host_en ? m_rdata : 32'h0;

  // ------------------------------------------------------------ decode
  logic [3:0] rgn;
  logic sel_rom, sel_acc, sel_mem, sel_aon, sel_bad;
  assign rgn     = m_addr[31:28];
  assign sel_rom = (rgn == soc_pkg::RGN_ROM);
  assign sel_acc = (rgn == soc_pkg::RGN_ACC);
  assign sel_mem = (rgn == soc_pkg::RGN_RAM) || (rgn == soc_pkg::RGN_UART);
  assign sel_aon = (rgn == soc_pkg::RGN_AON);
  assign sel_bad = ~(sel_rom | sel_acc | sel_mem | sel_aon);

  // ------------------------------------------------------------ fence
  logic fence;
  logic remote_inflight;
  logic mem_rdy_i, aon_rdy_i;
  logic [31:0] mem_rdata_i;
  logic acc_busy;

  assign remote_inflight = m_valid & (sel_mem | sel_aon) & ~fence;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                    fence <= 1'b0;
    else if (!pwr_req)             fence <= 1'b0;
    else if (!remote_inflight)     fence <= 1'b1;
  end
  assign pwr_ack = fence & ~acc_busy;

  // ------------------------------------------------------------ local slaves
  logic        rom_fire, rom_ready;
  logic [31:0] rom_word, rom_rdata;
  bus_slave_ack u_rom_ack (.clk(clk), .rst_n(rst_n), .valid(m_valid & sel_rom),
                           .fire(rom_fire), .ready(rom_ready));
  boot_rom #(.WORDS(ROM_WORDS)) u_rom (.addr(m_addr[$clog2(ROM_WORDS)+1:2]), .data(rom_word));
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rom_rdata <= '0; else if (rom_fire) rom_rdata <= rom_word;

  logic        acc_ready;
  logic [31:0] acc_rdata;
  mac_accel #(.N(N)) u_acc (
    .clk(clk), .rst_n(rst_n), .test_en(test_en),
    .valid(m_valid & sel_acc), .addr(m_addr[11:0]), .wdata(m_wdata), .wstrb(m_wstrb),
    .rdata(acc_rdata), .ready(acc_ready),
    .busy(acc_busy), .mac_clk_en(mac_clk_en),
    .cfg_q(ret_cfg_q), .restore(restore), .cfg_ret(ret_cfg_d)
  );

  // Unmapped region: respond with 0xDEADBEEF so software sees a clear error
  logic bad_fire, bad_ready;
  bus_slave_ack u_bad_ack (.clk(clk), .rst_n(rst_n), .valid(m_valid & sel_bad),
                           .fire(bad_fire), .ready(bad_ready));

  // ------------------------------------------------------------ remote ports
  logic        mem_valid_c, aon_valid_c;
  assign mem_valid_c = m_valid & sel_mem & ~fence;
  assign aon_valid_c = m_valid & sel_aon & ~fence;

  // Operand isolation: address/data only toggle on a real access, so an
  // idle PD_CMP causes no switching in PD_MEM / PD_AON (and no X leaks out
  // of the CPU's undefined post-reset bus in simulation).
  logic [67:0] mem_payload, aon_payload;
  assign mem_payload = mem_valid_c ? {m_addr, m_wdata, m_wstrb} : '0;
  assign aon_payload = aon_valid_c ? {m_addr, m_wdata, m_wstrb} : '0;

  // Leaving PD_CMP: X while powered off (PWR_SIM), isolated by the receiver.
  pd_out #(.W(1+68)) u_out_mem (.pwr_good(pwr_good), .d({mem_valid_c, mem_payload}),
    .q({mem_valid, mem_addr, mem_wdata, mem_wstrb}));
  pd_out #(.W(1+68)) u_out_aon (.pwr_good(pwr_good), .d({aon_valid_c, aon_payload}),
    .q({aon_valid, aon_addr, aon_wdata, aon_wstrb}));

  // Entering PD_CMP from PD_MEM: isolate while PD_MEM is off. PD_MEM runs at
  // the fixed 1.80 V, so no level shifter is needed (high -> low is safe).
  iso_clamp0 #(.W(33)) u_iso_mem (.iso(mem_iso), .d({mem_ready, mem_rdata}),
                                  .q({mem_rdy_i, mem_rdata_i}));
  assign aon_rdy_i = aon_ready;   // PD_AON never powers off

  // ------------------------------------------------------------ response mux
  assign m_ready = rom_ready | acc_ready | bad_ready |
                   (mem_rdy_i & sel_mem) | (aon_rdy_i & sel_aon);

  always_comb begin
    m_rdata = 32'hDEAD_BEEF;
    if (sel_rom)      m_rdata = rom_rdata;
    else if (sel_acc) m_rdata = acc_rdata;
    else if (sel_mem) m_rdata = mem_rdata_i;
    else if (sel_aon) m_rdata = aon_rdata;
  end

  assign trap = cpu_trap;

`ifdef PWR_SIM
  // CPU register file has no reset: model loss of contents at power-off.
  always @(negedge rst_n) begin
    for (int r = 0; r < 32; r++) u_cpu.cpuregs[r] = 'x;
  end
`endif

endmodule
