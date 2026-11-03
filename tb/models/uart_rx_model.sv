// uart_rx_model.sv - 8N1 receiver for the console. Samples on the SoC's own
// clk_sys with the divisor read from the UART, so it follows DVFS changes.
// Prints each line and raises `pass` on "PASS" and `fail` on "FAIL".
`timescale 1ns/1ps
module uart_rx_model (
  input  logic        clk,
  input  logic [15:0] div,
  input  logic        rx,
  output logic        pass,
  output logic        fail,
  output int          nchars
);
  string line;
  initial begin
    pass   = 1'b0;
    fail   = 1'b0;
    nchars = 0;
    line   = "";
  end

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
  endtask

  initial begin : rx_loop
    logic [7:0] ch;
    forever begin
      @(negedge rx);
      wait_cycles((div > 1) ? div / 2 : 1);
      if (rx === 1'b0) begin                   // still low: a real start bit
        for (int b = 0; b < 8; b++) begin
          wait_cycles(div);
          ch[b] = rx;
        end
        wait_cycles(div);                      // stop bit
        nchars++;
        if (ch == 8'h0A) begin
          $display("[%0t] UART | %s", $time, line);
          for (int i = 0; i + 4 <= line.len(); i++) begin
            if (line.substr(i, i + 3) == "PASS") pass = 1'b1;
            if (line.substr(i, i + 3) == "FAIL") fail = 1'b1;
          end
          line = "";
        end else begin
          line = $sformatf("%s%c", line, ch);
        end
      end
    end
  end
endmodule
