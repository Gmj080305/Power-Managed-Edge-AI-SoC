// soc.h - register map of the power-managed edge-AI SoC (matches soc_pkg.sv)
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))

// Accelerator (PD_CMP)
#define ACC_BASE      0x20000000u
#define ACC_CTRL      REG32(ACC_BASE + 0x000)
#define ACC_STATUS    REG32(ACC_BASE + 0x004)
#define ACC_CFG       REG32(ACC_BASE + 0x008)
#define ACC_CYCLES    REG32(ACC_BASE + 0x00C)
#define ACC_INFO      REG32(ACC_BASE + 0x010)
#define ACC_A(w)      REG32(ACC_BASE + 0x100 + 4u * (w))
#define ACC_B(w)      REG32(ACC_BASE + 0x200 + 4u * (w))
#define ACC_C(w)      REG32(ACC_BASE + 0x400 + 4u * (w))
#define ACC_ST_BUSY   0x1u
#define ACC_ST_DONE   0x2u
#define ACC_CFG_RELU  0x100u

// PMU / always-on registers (PD_AON)
#define AON_BASE        0x30000000u
#define PMU_CTRL        REG32(AON_BASE + 0x00)
#define PMU_STATUS      REG32(AON_BASE + 0x04)
#define PMU_WAKE_TIMER  REG32(AON_BASE + 0x08)
#define PMU_WAKE_MASK   REG32(AON_BASE + 0x0C)
#define PMU_SEQ_CFG     REG32(AON_BASE + 0x10)
#define PMU_BOOT_REASON REG32(AON_BASE + 0x14)
#define PMU_WAKE_CNT    REG32(AON_BASE + 0x18)
#define PMU_RET_ACC     REG32(AON_BASE + 0x1C)
#define PMU_SCRATCH(i)  REG32(AON_BASE + 0x20 + 4u * (i))

#define PS_ACTIVE_H 0u
#define PS_ACTIVE_L 1u
#define PS_IDLE     2u
#define PS_SLEEP    3u

#define ST_PSTATE(s)  ((s) & 3u)
#define ST_BUSY       (1u << 2)
#define ST_ERR        (1u << 3)
#define ST_FREQ_LO    (1u << 7)
#define ST_VSEL_HI    (1u << 8)

#define WK_TIMER 0x1u
#define WK_GPIO  0x2u
#define WK_HOST  0x4u

#define BR_WARM        0x1u
#define BR_FROM(b)     (((b) >> 1) & 3u)
#define BR_SRC(b)      (((b) >> 4) & 7u)

// UART (PD_MEM)
#define UART_BASE   0x40000000u
#define UART_TX     REG32(UART_BASE + 0x0)
#define UART_STATUS REG32(UART_BASE + 0x4)
#define UART_DIV    REG32(UART_BASE + 0x8)

#endif
