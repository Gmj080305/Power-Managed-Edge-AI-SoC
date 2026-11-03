// uart_tx.sv - 8N1 transmitter. Bit time = DIV clock cycles (DIV >= 1).
// TX register write starts a frame; STATUS bit0 = busy.
module uart_tx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [7:0]  data,
  input  logic [15:0] div,
  output logic        busy,
  output logic        tx
);
  logic [9:0]  shreg;
  logic [3:0]  nbits;
  logic [15:0] cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shreg <= '1;
      nbits <= '0;
      cnt   <= '0;
      busy  <= 1'b0;
      tx    <= 1'b1;
    end else if (!busy) begin
      if (start) begin
        shreg <= {1'b1, data, 1'b0};   // stop, data (LSB first), start
        nbits <= 4'd10;
        cnt   <= '0;
        busy  <= 1'b1;
      end
    end else if (cnt == '0) begin
      tx    <= shreg[0];
      shreg <= {1'b1, shreg[9:1]};
      nbits <= nbits - 1'b1;
      cnt   <= (div == '0) ? 16'd0 : div - 1'b1;
      if (nbits == 4'd0) begin
        busy <= 1'b0;
        tx   <= 1'b1;
      end
    end else begin
      cnt <= cnt - 1'b1;
    end
  end
endmodule
