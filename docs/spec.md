# Specification

## Power domains

| Domain | Contents | Supply | Behaviour |
| --- | --- | --- | --- |
| PD_AON | PMU (`pmu_fsm`), clock/reset control, wake timer and pins, retention shadow, AON registers, pad-side isolation, top-level glue | VDD_AON 1.80 V | never off |
| PD_CMP | PicoRV32 (RV32IMC), 4 KB boot ROM, MAC accelerator, bus fabric, debug host port | VDD_CMP 1.80 V (OPP-H) / ~1.50 V (OPP-L) | DVFS; switched off in IDLE and SLEEP |
| PD_MEM | 512 B scratch RAM, UART | VDD_MEM 1.80 V | switched off in SLEEP |

## Power states

| State | PD_CMP | PD_MEM | clk_sys | Entered by | Left by |
| --- | --- | --- | --- | --- | --- |
| ACTIVE_H | on, 1.80 V | on | clk_in | reset, request, wake | request |
| ACTIVE_L | on, ~1.50 V | on | clk_in / 2 | request, wake | request |
| IDLE | off | on | gated off in PD_CMP | request (needs a wake source) | enabled wake event |
| SLEEP | off | off | gated off in both | request (needs a wake source) | enabled wake event |

A wake returns to the OPP the SoC was at before powering down. **CMP on with
MEM off is illegal**: MEM is powered up before CMP and powered down after it,
and the formal proof shows the PMU never requests that state.

Requests are refused and flagged (`PMU_STATUS.err`) when: the target code is
4-7, the PMU is busy, the SoC is not active, or IDLE/SLEEP is requested with
no wake source enabled. Requesting the current state is a legal no-op.

## Clocks and resets

- One root clock: `clk_sys` = `clk_in` (OPP-H) or `clk_in/2` (OPP-L) through a
  glitch-free switch (`clk_switch`, break-before-make on falling edges). PD_AON
  runs on ungated `clk_sys`; PD_CMP, PD_MEM and the MAC array get integrated
  clock gates. Every bus crossing is therefore synchronous.
- `clk_32k` (32.768 kHz) clocks only the wake-timer counter.
- `por_n` is synchronised per clock domain (async assert, sync de-assert).
  Domain resets are `rst_sys_n & <PMU reset>`.

### Clock-domain crossings

| Signal | From -> to | Method |
| --- | --- | --- |
| timer arm | clk_sys -> clk_32k | toggle + 2-flop sync |
| timer expiry | clk_32k -> clk_sys | toggle + 2-flop sync + edge detect |
| timer period | clk_sys -> clk_32k | quasi-static: written long before the arm toggle arrives |
| gpio_wake, host_wake | pin -> clk_sys | 2-flop sync + edge detect |
| clock-switch status | clk_in / clk_in/2 -> clk_sys | 2-flop sync |
| `vdd_ok`, `sw_ack_cmp`, `sw_ack_mem` | regulator / power switches -> clk_sys | 2-flop sync, reset value 1 (power-on state); false path in the SDC (v1.0) |

## Domain crossings

Protection cells sit in the **receiving** domain. A level shifter comes first
when the source can be at the lower voltage, then the isolation cell.

| From -> to | Signals | Level shifter | Isolation (clamp) | Enable |
| --- | --- | --- | --- | --- |
| CMP -> MEM | valid, addr, wdata, wstrb | `ls_lh` | `iso_clamp0` (0) | `cmp_iso` |
| CMP -> AON | valid, addr, wdata, wstrb, quiesce ack, retained config, trap | `ls_lh` | `iso_clamp0` (0) | `cmp_iso` |
| CMP -> pins | host_rdata, host_ready | `ls_lh` | `iso_clamp0` (0) | `cmp_iso` |
| MEM -> CMP | rdata, ready | none (1.80 V -> lower is safe) | `iso_clamp0` (0) | `mem_iso` |
| MEM -> pin | uart_tx | none | `iso_clamp1` (1, idle level) | `mem_iso` |
| AON -> CMP / MEM | clocks, resets, restore, retained config, PMU controls | none | none (source never off) | - |

`scripts/check_crossings.py` checks this table against the elaborated netlist.
Address and write data leaving PD_CMP are also gated with `valid` (operand
isolation), so an idle PD_CMP causes no switching in the receivers.

Cell mapping (Sky130 HD): `iso_clamp0` -> `lpflow_isobufsrc_1` (X = A & !SLEEP),
`iso_clamp1` -> `lpflow_inputiso1p_1` (X = A | SLEEP), `ls_lh` ->
`lpflow_lsbuf_lh_isowell_4` (LOWLVPWR = low supply), `icg` -> `dlclkp_1`.

## PMU sequences

Each step changes one registered control output, waits at least `SEQ_CFG`
cycles, then waits for its acknowledge where it has one.

| Transition | Steps |
| --- | --- |
| DVFS H -> L | frequency low (wait switch ack) -> voltage low (wait `vdd_ok`) |
| DVFS L -> H | voltage high (wait `vdd_ok`) -> frequency high (wait switch ack) |
| CMP down | quiesce request (wait ack) -> clock off -> **save** -> isolate -> reset -> switch off (wait ack low) |
| MEM down (SLEEP) | clock off -> isolate -> reset -> switch off (wait ack low) |
| MEM up | switch on (wait ack) -> clock on -> reset release -> isolation off |
| CMP up | switch on (wait ack) -> clock on -> reset release -> **restore** -> isolation off |

Why this order:

- **Quiesce first.** The fabric stops issuing transactions to PD_MEM/PD_AON once
  none is in flight (the fence) and the accelerator must be idle, so no
  transfer is cut in half.
- **Save before isolation.** The retention shadow lives in PD_AON and reads the
  PD_CMP register across the boundary; once isolated it would read the clamp
  value. With in-place retention flops (UPF `set_retention`) save could follow
  isolation.
- **Isolate before switching off, release after restore.** A receiver must never
  see a floating or X input, and must not see stale state.
- **Clock on before reset release.** PicoRV32 has a synchronous reset: without
  clock edges during reset it would resume where it stopped. Simulation found
  this; see `CHANGELOG.md`.
- **Voltage before frequency going up, frequency before voltage going down.**
  The clock may never be faster than the present voltage allows, even for one
  cycle.

Wake events count from the start of a power-down: an event that arrives
mid-sequence is latched, the sequence completes, and the PMU wakes
immediately. The wake timer is armed at the start of each power-down.

## Retention

| What | Mechanism | Survives |
| --- | --- | --- |
| Accelerator config (K, ReLU) | hardware: AON shadow, `save` / `restore` pulses | IDLE, SLEEP |
| Boot reason, wake count | AON registers | IDLE, SLEEP |
| 4 scratch words | software: AON registers | IDLE, SLEEP |
| Scratch RAM, `.noinit` section | PD_MEM stays powered | IDLE only |
| CPU registers, A/B/C buffers | none - firmware rebuilds them | nothing |

## Address map

| Base | Block | Domain |
| --- | --- | --- |
| `0x0000_0000` | boot ROM, 4 KB | PD_CMP |
| `0x1000_0000` | scratch RAM, 512 B | PD_MEM |
| `0x2000_0000` | accelerator | PD_CMP |
| `0x3000_0000` | PMU / AON registers | PD_AON |
| `0x4000_0000` | UART | PD_MEM |
| other | reads `0xDEADBEEF` | - |

### Accelerator (`0x2000_0000`)

| Offset | Name | Access | Fields |
| --- | --- | --- | --- |
| 0x000 | CTRL | W | bit0 start |
| 0x004 | STATUS | R | bit0 busy, bit1 done (cleared by start) |
| 0x008 | CFG | RW | [3:0] K (0 = N), bit8 ReLU - **retained** |
| 0x00C | CYCLES | R | cycles of the last job (= K + 2N + 1) |
| 0x010 | INFO | R | [7:0] N |
| 0x100 | A | RW | A[i][k] = byte i*N + k |
| 0x200 | B | RW | B[k][j] = byte k*N + j |
| 0x400 | C | R | C[i][j] = word i*N + j (INT32) |

C = A x B with A N x K and B K x N, INT8 operands, INT32 accumulation, optional
ReLU. The array is output-stationary and runs on its own gated clock.

### PMU / AON (`0x3000_0000`)

| Offset | Name | Access | Fields |
| --- | --- | --- | --- |
| 0x00 | PMU_CTRL | W / R | [2:0] target state (write = request) |
| 0x04 | PMU_STATUS | R / W | [1:0] state, [2] busy, [3] err, [6:4] last wake source, [7] f/2 active, [8] vsel_hi, [9] vdd_ok, [10] CMP switch on, [11] MEM switch on; write clears err |
| 0x08 | WAKE_TIMER | RW | [23:0] period in 32 kHz ticks |
| 0x0C | WAKE_MASK | RW | bit0 timer, bit1 GPIO, bit2 host |
| 0x10 | SEQ_CFG | RW | [7:0] minimum cycles per sequencer step (reset 2) |
| 0x14 | BOOT_REASON | R / W | [0] warm, [2:1] woken from, [6:4] wake source; write clears |
| 0x18 | WAKE_CNT | R | wakes since power-on |
| 0x1C | RET_ACC | R | retention shadow contents |
| 0x20-0x2C | SCRATCH0-3 | RW | always-on scratch |

### UART (`0x4000_0000`)

| Offset | Name | Fields |
| --- | --- | --- |
| 0x0 | TX | write a byte to send |
| 0x4 | STATUS | bit0 busy |
| 0x8 | DIV | clock cycles per bit (reset 16) |

## Pins

`clk_in`, `clk_32k`, `por_n`, `test_en` (clock-gate override), `gpio_wake`,
`host_wake`, debug host port (`host_en`, `host_valid`, `host_addr`,
`host_wdata`, `host_wstrb`, `host_rdata`, `host_ready`; `host_en` holds the CPU
in reset), `uart_tx`, `cpu_trap`, and the power-delivery interface:
`vsel_hi` / `vdd_ok` to the regulator, `sw_en_*` / `sw_ack_*` to the power
switches.

## Design decisions

- **Flop-based memories** keep every tool flow portable (no SRAM macro). They
  dominate area and leakage (see results), which makes the SLEEP saving large;
  an SRAM macro with retention banks is a stretch goal.
- **Power switches and regulator are modelled**, not designed: Sky130 HD has no
  power-switch cell.
- **The debug host port** lets the class-based testbench run register-level
  constrained-random tests with the CPU held in reset.
