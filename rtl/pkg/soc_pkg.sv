// soc_pkg.sv - shared constants for the power-managed edge-AI SoC.
// Kept to plain localparams so every frontend reads it: Yosys (built-in
// and slang), the Verilator and Icarus simulators, and Vivado xsim.
package soc_pkg;

  // ---------------------------------------------------------------- power
  // Stable power states reported in PMU_STATUS[1:0]
  localparam logic [1:0] PS_ACTIVE_H = 2'd0;  // CMP on, OPP-H (1.80 V, f)
  localparam logic [1:0] PS_ACTIVE_L = 2'd1;  // CMP on, OPP-L (~1.50 V, f/2)
  localparam logic [1:0] PS_IDLE     = 2'd2;  // CMP off, MEM on
  localparam logic [1:0] PS_SLEEP    = 2'd3;  // CMP off, MEM off

  // Wake-source bits (PMU_WAKE_MASK and BOOT_REASON wake source field)
  localparam int WK_TIMER = 0;
  localparam int WK_GPIO  = 1;
  localparam int WK_HOST  = 2;

  // ------------------------------------------------------------ address map
  // Region = addr[31:28]
  localparam logic [3:0] RGN_ROM  = 4'h0;  // boot ROM          PD_CMP
  localparam logic [3:0] RGN_RAM  = 4'h1;  // scratch RAM       PD_MEM
  localparam logic [3:0] RGN_ACC  = 4'h2;  // MAC accelerator   PD_CMP
  localparam logic [3:0] RGN_AON  = 4'h3;  // PMU / AON regs    PD_AON
  localparam logic [3:0] RGN_UART = 4'h4;  // UART              PD_MEM

  // AON register byte offsets (addr[7:0])
  localparam logic [7:0] AON_PMU_CTRL    = 8'h00;
  localparam logic [7:0] AON_PMU_STATUS  = 8'h04;
  localparam logic [7:0] AON_WAKE_TIMER  = 8'h08;
  localparam logic [7:0] AON_WAKE_MASK   = 8'h0C;
  localparam logic [7:0] AON_SEQ_CFG     = 8'h10;
  localparam logic [7:0] AON_BOOT_REASON = 8'h14;
  localparam logic [7:0] AON_WAKE_CNT    = 8'h18;
  localparam logic [7:0] AON_RET_ACC     = 8'h1C;
  localparam logic [7:0] AON_SCRATCH0    = 8'h20;  // ..0x2C, 4 words

  // Accelerator register byte offsets (addr[11:0])
  localparam logic [11:0] ACC_CTRL   = 12'h000;
  localparam logic [11:0] ACC_STATUS = 12'h004;
  localparam logic [11:0] ACC_CFG    = 12'h008;
  localparam logic [11:0] ACC_CYCLES = 12'h00C;
  localparam logic [11:0] ACC_INFO   = 12'h010;
  localparam logic [11:0] ACC_A_BASE = 12'h100;
  localparam logic [11:0] ACC_B_BASE = 12'h200;
  localparam logic [11:0] ACC_C_BASE = 12'h400;

  // UART register byte offsets (addr[3:0])
  localparam logic [3:0] UART_TX     = 4'h0;
  localparam logic [3:0] UART_STATUS = 4'h4;
  localparam logic [3:0] UART_DIV    = 4'h8;

endpackage
