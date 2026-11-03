// main.c - firmware for the power-managed edge-AI SoC.
//
// One image covers the whole power-management story. Each boot reads
// BOOT_REASON to find out where it is in the sequence:
//   cold boot  : accelerator self-test, illegal-request checks, DVFS round
//                trip, then request IDLE (timer wake)
//   from IDLE  : RAM (PD_MEM stayed on) and accelerator config (hardware
//                retention) must have survived; go to ACTIVE_L, then
//                request SLEEP (GPIO / host wake)
//   from SLEEP : software-retained AON scratch and hardware-retained config
//                must have survived, the SoC must be back at ACTIVE_L; run
//                the accelerator again and finish
// The testbench watches the UART for "PASS" or "FAIL".
#include "soc.h"

#define MAGIC_IDLE   0x1D1E0001u
#define MAGIC_SLEEP  0x51EE0002u
#define RET_CFG      (ACC_CFG_RELU | 2u)   // K = 2, ReLU on
#define NOINIT_WORDS 8

static volatile uint32_t noinit_buf[NOINIT_WORDS] __attribute__((section(".noinit")));

// ---------------------------------------------------------------- console
static void putc_(char c) {
  while (UART_STATUS & 1u) { }
  UART_TX = (uint8_t)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint32_t v, int digits) {
  for (int i = digits - 1; i >= 0; i--) {
    uint32_t n = (v >> (4 * i)) & 0xFu;
    putc_((char)(n < 10 ? '0' + n : 'a' + n - 10));
  }
}
static void flush(void) { while (UART_STATUS & 1u) { } }

static void fail(uint32_t code) {
  puts_("FAIL ");
  puthex(code, 4);
  putc_('\n');
  flush();
  for (;;) { }
}
#define CHECK(cond, code) do { if (!(cond)) fail(code); } while (0)

// ---------------------------------------------------------------- PMU
static void pmu_request(uint32_t target) {
  PMU_CTRL = target;
  for (;;) {
    uint32_t s = PMU_STATUS;
    if (!(s & ST_BUSY) && ST_PSTATE(s) == target) return;
  }
}

static void power_down(uint32_t target) {
  flush();
  PMU_CTRL = target;   // the PMU quiesces, isolates and switches PD_CMP off
  for (;;) { }         // never returns: the next boot is a warm boot
}

// ---------------------------------------------------------------- MAC
// Operands are a deterministic hash of (seed, index): no RAM needed for them.
static int8_t elem(uint32_t seed, uint32_t idx) {
  uint32_t x = (seed ^ (idx * 0x9E3779B1u)) * 0x85EBCA6Bu;
  x ^= x >> 13;
  x *= 0xC2B2AE35u;
  x ^= x >> 16;
  uint32_t sel = x & 0xFu;
  if (sel == 0) return 127;          // corner values on purpose
  if (sel == 1) return -128;
  return (int8_t)(x >> 24);
}

static void mac_run_check(uint32_t n, uint32_t k, uint32_t relu, uint32_t seed, uint32_t code) {
  // A is N x K stored in an N x N grid (row stride N); B is K x N likewise.
  for (uint32_t w = 0; w < (n * n + 3) / 4; w++) {
    uint32_t wa = 0, wb = 0;
    for (uint32_t l = 0; l < 4; l++) {
      uint32_t idx = 4 * w + l;
      wa |= (uint32_t)(uint8_t)elem(seed, idx) << (8 * l);
      wb |= (uint32_t)(uint8_t)elem(seed + 1u, idx) << (8 * l);
    }
    ACC_A(w) = wa;
    ACC_B(w) = wb;
  }
  ACC_CFG = (relu ? ACC_CFG_RELU : 0u) | k;
  ACC_CTRL = 1u;
  while (!(ACC_STATUS & ACC_ST_DONE)) { }

  for (uint32_t i = 0; i < n; i++) {
    for (uint32_t j = 0; j < n; j++) {
      int32_t ref = 0;
      for (uint32_t kk = 0; kk < k; kk++)
        ref += (int32_t)elem(seed, i * n + kk) * (int32_t)elem(seed + 1u, kk * n + j);
      if (relu && ref < 0) ref = 0;
      CHECK((int32_t)ACC_C(i * n + j) == ref, code);
    }
  }
}

// ---------------------------------------------------------------- phases
static void cold_boot(uint32_t n) {
  puts_("BOOT cold N=");
  puthex(n, 1);
  putc_('\n');

  // 1. accelerator self-test at OPP-H
  mac_run_check(n, n, 0, 0x1234u, 0x0101);
  mac_run_check(n, n > 1 ? n - 1 : 1, 1, 0xBEEFu, 0x0102);
  puts_("MAC ok cyc=");
  puthex(ACC_CYCLES, 4);
  putc_('\n');

  // 2. illegal requests are refused and flagged
  PMU_WAKE_MASK = 0;
  PMU_CTRL = PS_IDLE;                       // no wake source: refused
  CHECK(PMU_STATUS & ST_ERR, 0x0201);
  CHECK(ST_PSTATE(PMU_STATUS) == PS_ACTIVE_H, 0x0202);
  PMU_STATUS = 0;                           // clear err
  PMU_CTRL = 6;                             // undefined target
  CHECK(PMU_STATUS & ST_ERR, 0x0203);
  PMU_STATUS = 0;
  CHECK(!(PMU_STATUS & ST_ERR), 0x0204);
  puts_("ERR ok\n");

  // 3. DVFS round trip, accelerator run at OPP-L
  pmu_request(PS_ACTIVE_L);
  CHECK(PMU_STATUS & ST_FREQ_LO, 0x0301);
  CHECK(!(PMU_STATUS & ST_VSEL_HI), 0x0302);
  mac_run_check(n, n, 0, 0x5555u, 0x0303);
  pmu_request(PS_ACTIVE_H);
  CHECK(!(PMU_STATUS & ST_FREQ_LO), 0x0304);
  CHECK(PMU_STATUS & ST_VSEL_HI, 0x0305);
  puts_("DVFS ok\n");

  // 4. prepare state that must survive IDLE, then power down
  ACC_CFG = RET_CFG;
  for (uint32_t i = 0; i < NOINIT_WORDS; i++) noinit_buf[i] = 0xA5000000u + i;
  PMU_SCRATCH(0) = MAGIC_IDLE;
  PMU_WAKE_TIMER = 3;
  PMU_WAKE_MASK = WK_TIMER;
  puts_("IDLE\n");
  power_down(PS_IDLE);
}

static void wake_from_idle(uint32_t br) {
  CHECK(PMU_SCRATCH(0) == MAGIC_IDLE, 0x0401);
  CHECK(BR_SRC(br) & WK_TIMER, 0x0402);
  CHECK(ACC_CFG == RET_CFG, 0x0403);                  // hardware retention
  for (uint32_t i = 0; i < NOINIT_WORDS; i++)
    CHECK(noinit_buf[i] == 0xA5000000u + i, 0x0404);  // PD_MEM stayed on
  puts_("WAKE idle ok\n");

  // Go to OPP-L before sleeping: the PMU must bring us back at OPP-L.
  pmu_request(PS_ACTIVE_L);
  PMU_SCRATCH(0) = MAGIC_SLEEP;
  PMU_SCRATCH(1) = PMU_WAKE_CNT;
  PMU_WAKE_MASK = WK_GPIO | WK_HOST;
  puts_("SLEEP\n");
  power_down(PS_SLEEP);
}

static void wake_from_sleep(uint32_t br, uint32_t n) {
  CHECK(PMU_SCRATCH(0) == MAGIC_SLEEP, 0x0501);       // software retention
  CHECK(PMU_WAKE_CNT == PMU_SCRATCH(1) + 1u, 0x0502);
  CHECK(BR_SRC(br) & (WK_GPIO | WK_HOST), 0x0503);
  CHECK(ST_PSTATE(PMU_STATUS) == PS_ACTIVE_L, 0x0504);
  CHECK(ACC_CFG == RET_CFG, 0x0505);
  puts_("WAKE sleep ok\n");

  // Accelerator buffers were lost with PD_CMP: reload and run again.
  mac_run_check(n, n, 1, 0x7777u, 0x0506);
  pmu_request(PS_ACTIVE_H);
  PMU_SCRATCH(0) = 0;
  puts_("DONE PASS\n");
  flush();
}

int main(void) {
  UART_DIV = 4;
  uint32_t n  = ACC_INFO & 0xFFu;
  uint32_t br = PMU_BOOT_REASON;
  PMU_BOOT_REASON = 0;

  if (!(br & BR_WARM))                 cold_boot(n);
  else if (BR_FROM(br) == PS_IDLE)     wake_from_idle(br);
  else if (BR_FROM(br) == PS_SLEEP)    wake_from_sleep(br, n);
  else                                 fail(0x0001);
  for (;;) { }
}
