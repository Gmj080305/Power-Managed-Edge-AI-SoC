// mem_top.sv - PD_MEM: scratch RAM + UART, a bus slave of PD_CMP.
// Signals arriving from PD_CMP pass a low->high level shifter (PD_CMP may be
// at ~1.50 V) and then an isolation cell clamped to 0 (valid = 0 means no
// access) while PD_CMP is off. Both live here, in the receiving domain.
module mem_top #(
  parameter int RAM_WORDS = 128
) (
  input  logic        clk,          // gated clk_mem
  input  logic        rst_n,
  input  logic        pwr_good,
  input  logic        cmp_iso,      // PD_CMP outputs isolated
  // from PD_CMP
  input  logic        valid,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  // to PD_CMP / pads
  output logic [31:0] rdata,
  output logic        ready,
  output logic        uart_tx
);
  localparam int AW = $clog2(RAM_WORDS);

  // ------------------------------------------------ receive from PD_CMP
  logic [68:0] in_ls, in_iso;
  ls_lh      #(.W(69)) u_ls  (.d({valid, addr, wdata, wstrb}), .q(in_ls));
  iso_clamp0 #(.W(69)) u_iso (.iso(cmp_iso), .d(in_ls), .q(in_iso));

  logic        v;
  logic [31:0] a, wd;
  logic [3:0]  ws;
  assign {v, a, wd, ws} = in_iso;

  // ------------------------------------------------ slave
  logic fire, rdy;
  bus_slave_ack u_ack (.clk(clk), .rst_n(rst_n), .valid(v), .fire(fire), .ready(rdy));

  logic is_ram, is_uart, wr;
  assign is_ram  = (a[31:28] == soc_pkg::RGN_RAM);
  assign is_uart = (a[31:28] == soc_pkg::RGN_UART);
  assign wr      = fire & (|ws);

  logic [31:0] ram_rdata;
  scratch_ram #(.WORDS(RAM_WORDS)) u_ram (
    .clk(clk), .we(wr & is_ram), .wstrb(ws), .waddr(a[AW+1:2]), .wdata(wd),
    .raddr(a[AW+1:2]), .rdata(ram_rdata));

  logic [15:0] uart_div;
  logic        uart_busy, uart_line;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) uart_div <= 16'd16;
    else if (wr && is_uart && a[3:0] == soc_pkg::UART_DIV) uart_div <= wd[15:0];
  end
  uart_tx u_uart (.clk(clk), .rst_n(rst_n),
                  .start(wr && is_uart && a[3:0] == soc_pkg::UART_TX),
                  .data(wd[7:0]), .div(uart_div), .busy(uart_busy), .tx(uart_line));

  logic [31:0] rd_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_q <= '0;
    else if (fire) begin
      if (is_ram)                                rd_q <= ram_rdata;
      else if (is_uart && a[3:0] == soc_pkg::UART_STATUS) rd_q <= {31'h0, uart_busy};
      else if (is_uart && a[3:0] == soc_pkg::UART_DIV)    rd_q <= {16'h0, uart_div};
      else                                       rd_q <= 32'h0;
    end
  end

  // ------------------------------------------------ leave PD_MEM
  pd_out #(.W(34)) u_out (.pwr_good(pwr_good), .d({rdy, rd_q, uart_line}),
                          .q({ready, rdata, uart_tx}));

`ifdef PWR_SIM
  always @(negedge rst_n) u_ram.corrupt();
`endif
endmodule
