// bus_slave_ack.sv - one-wait-state handshake shared by every slave.
// `ready` pulses for one cycle per request. `fire` marks the cycle in which
// the slave performs the access (write, or capture of read data). It works
// even if the master keeps `valid` high back to back.
module bus_slave_ack (
  input  logic clk,
  input  logic rst_n,
  input  logic valid,
  output logic fire,
  output logic ready
);
  assign fire = valid & ~ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ready <= 1'b0;
    else        ready <= fire;
  end
endmodule
