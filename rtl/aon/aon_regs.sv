// aon_regs.sv - PMU register file (PD_AON), bus slave of PD_CMP.
//   0x00 PMU_CTRL     W  [2:0] target state (write = request)    R last target
//   0x04 PMU_STATUS   R  [1:0] pstate [2] busy [3] err [6:4] last wake src
//                        [7] f/2 active [8] vsel_hi [9] vdd_ok
//                        [10] CMP switch on [11] MEM switch on
//                     W  any value clears err
//   0x08 WAKE_TIMER   RW [23:0] period in 32 kHz ticks
//   0x0C WAKE_MASK    RW [2:0] {host, gpio, timer}
//   0x10 SEQ_CFG      RW [7:0] minimum cycles per sequencer step
//   0x14 BOOT_REASON  R  [0] warm [2:1] woken from [6:4] wake src; W clears
//   0x18 WAKE_CNT     R  number of wakes since power-on
//   0x1C RET_ACC      R  retention shadow of the accelerator config
//   0x20-0x2C SCRATCH RW four always-on words (software retention)
module aon_regs (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        valid,
  input  logic [7:0]  addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,
  output logic        ready,
  // to / from PMU
  output logic        req_valid,
  output logic [2:0]  req_target,    // valid with req_valid (= write data)
  output logic [23:0] wake_period,
  output logic [2:0]  wake_mask,
  output logic [7:0]  seq_wait,
  input  logic [1:0]  pstate,
  input  logic        busy,
  input  logic        err_pulse,
  input  logic        wake_start,
  input  logic [2:0]  wake_src,
  input  logic [1:0]  wake_from,
  input  logic        freq_lo_ack,
  input  logic        vsel_hi,
  input  logic        vdd_ok,
  input  logic        cmp_sw_en,
  input  logic        mem_sw_en,
  input  logic [8:0]  ret_shadow
);

  logic fire, wr;
  bus_slave_ack u_ack (.clk(clk), .rst_n(rst_n), .valid(valid), .fire(fire), .ready(ready));
  assign wr = fire & (|wstrb);

  logic        err;
  logic [6:0]  boot_reason;
  logic [15:0] wake_cnt;
  logic [31:0] scratch [4];

  logic [2:0] last_target;
  assign req_valid  = wr && (addr == soc_pkg::AON_PMU_CTRL);
  assign req_target = wdata[2:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_target <= 3'd0;
      wake_period <= 24'd0;
      wake_mask   <= 3'd0;
      seq_wait    <= 8'd2;
      err         <= 1'b0;
      boot_reason <= 7'd0;
      wake_cnt    <= 16'd0;
      for (int i = 0; i < 4; i++) scratch[i] <= 32'h0;
    end else begin
      if (wr) begin
        case (addr)
          soc_pkg::AON_PMU_CTRL:    last_target <= wdata[2:0];
          soc_pkg::AON_PMU_STATUS:  err         <= 1'b0;
          soc_pkg::AON_WAKE_TIMER:  wake_period <= wdata[23:0];
          soc_pkg::AON_WAKE_MASK:   wake_mask   <= wdata[2:0];
          soc_pkg::AON_SEQ_CFG:     seq_wait    <= wdata[7:0];
          soc_pkg::AON_BOOT_REASON: boot_reason <= 7'd0;
          default: begin
            if (addr[7:4] == 4'h2) scratch[addr[3:2]] <= wdata;
          end
        endcase
      end
      if (err_pulse)  err <= 1'b1;
      if (wake_start) begin
        boot_reason <= {wake_src, 1'b0, wake_from, 1'b1};
        wake_cnt    <= wake_cnt + 16'd1;
      end
    end
  end

  logic [31:0] rd_mux;
  always_comb begin
    case (addr)
      soc_pkg::AON_PMU_CTRL:    rd_mux = {29'h0, last_target};
      soc_pkg::AON_PMU_STATUS:  rd_mux = {20'h0, mem_sw_en, cmp_sw_en, vdd_ok, vsel_hi, freq_lo_ack,
                                 boot_reason[6:4], err, busy, pstate};
      soc_pkg::AON_WAKE_TIMER:  rd_mux = {8'h0, wake_period};
      soc_pkg::AON_WAKE_MASK:   rd_mux = {29'h0, wake_mask};
      soc_pkg::AON_SEQ_CFG:     rd_mux = {24'h0, seq_wait};
      soc_pkg::AON_BOOT_REASON: rd_mux = {25'h0, boot_reason};
      soc_pkg::AON_WAKE_CNT:    rd_mux = {16'h0, wake_cnt};
      soc_pkg::AON_RET_ACC:     rd_mux = {23'h0, ret_shadow};
      default:         rd_mux = (addr[7:4] == 4'h2) ? scratch[addr[3:2]] : 32'h0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rdata <= 32'h0; else if (fire) rdata <= rd_mux;
endmodule
