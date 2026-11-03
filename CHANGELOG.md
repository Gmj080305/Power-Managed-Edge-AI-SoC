# Changelog

## v0.1.0 - initial import

First complete version of the 10-step plan.

- RTL: 3-domain SoC (PD_AON, PD_CMP, PD_MEM) with PicoRV32, INT8 systolic MAC
  accelerator (N = 2..8), PMU with power gating, retention and 2-point DVFS,
  32 kHz wake timer, GPIO and host wake, isolation / level-shifter / clock-gate
  wrappers mapped to Sky130 low-power cells.
- Firmware covering cold boot, self-test, illegal requests, DVFS, IDLE and
  SLEEP with warm boot.
- Verification: class-based SystemVerilog environment (7 tests), bound SVA,
  power-aware X testbench with fault injection, formal proof of 14 PMU
  properties, structural crossing check.
- Physical design: ORFS configs for Sky130 (baseline, power-managed,
  accelerator, experimental multi-domain) and ASAP7 multi-Vt; per-domain power
  and corner STA scripts; UPF power intent.
- Automation: `scripts/run.py`, VS Code tasks, `verify` and `pnr` GitHub
  workflows, Codespaces dev container.

Bugs the verification flow caught while building it:

- Accelerator ReLU bit and BOOT_REASON fields packed into the wrong bit
  positions (Verilator lint width warnings).
- PMU sampled the previous `PMU_CTRL` value: register update and request pulse
  happened in the same cycle (firmware illegal-request check failed).
- Power-up released reset with the clock gated; PicoRV32's synchronous reset
  never took effect and the CPU resumed its old loop after wake (firmware
  stalled after IDLE). Sequence changed to clock-on before reset release.
- The 32 kHz domain missed power-on reset when POR was shorter than a slow
  clock period (wake timer never fired) - testbench POR now covers it; a real
  POR circuit must too.
