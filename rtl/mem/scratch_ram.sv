// scratch_ram.sv - flop-based scratch RAM with byte enables.
// Flops keep the flow simple and portable (no SRAM macro); contents survive
// IDLE (PD_MEM stays on) and are lost in SLEEP.
module scratch_ram #(
  parameter int WORDS = 128
) (
  input  logic                      clk,
  input  logic                      we,
  input  logic [3:0]                wstrb,
  input  logic [$clog2(WORDS)-1:0]  waddr,
  input  logic [31:0]               wdata,
  input  logic [$clog2(WORDS)-1:0]  raddr,
  output logic [31:0]               rdata
);
  logic [31:0] mem [WORDS];

  always_ff @(posedge clk) begin
    if (we) begin
      for (int l = 0; l < 4; l++)
        if (wstrb[l]) mem[waddr][l*8 +: 8] <= wdata[l*8 +: 8];
    end
  end
  assign rdata = mem[raddr];

`ifdef PWR_SIM
  // Called by mem_top when the domain loses power.
  task automatic corrupt();
    for (int w = 0; w < WORDS; w++) mem[w] = 'x;
  endtask
`endif
endmodule
