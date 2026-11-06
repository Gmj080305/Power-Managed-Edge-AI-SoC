# Theory

Everything you need to understand this project, from flip-flops to sign-off,
explained against the actual files in this repo. Read it in order the first
time; later, use the table below to jump to a topic.

How to read it:

- **Code pointers** look like `rtl/aon/pmu_fsm.sv`. Open the file next to the
  text; every concept here exists somewhere in the code.
- **Formulas** are kept to the ones you will actually use or be asked about.
- Each part ends with **check yourself** questions. If you can answer them out
  loud without looking, you understand the part. Short answers are at the end.

| Part | Topic | Where it lives in the repo |
| --- | --- | --- |
| 1 | Digital design foundations | every RTL file |
| 2 | SoC architecture, RISC-V, firmware | `rtl/cmp/cmp_top.sv`, `fw/` |
| 3 | The INT8 systolic accelerator | `rtl/cmp/mac_*.sv` |
| 4 | Where power goes | `docs/use_case.md` |
| 5 | Low-power techniques | `rtl/common/`, `rtl/aon/` |
| 6 | The PMU and power sequencing | `rtl/aon/pmu_fsm.sv` |
| 7 | Clocks, resets and clock-domain crossing | `rtl/common/sync_2ff.sv`, `rtl/aon/wake_timer.sv` |
| 8 | Power intent: UPF | `upf/soc.upf` |
| 9 | Verification | `tb/`, `formal/` |
| 10 | From RTL to silicon: synthesis, STA, place and route | `flow/` |
| 11 | One wake-up, end to end | everything |
| 12 | Interview-style questions with answers | - |
| 13 | Glossary | - |

---

## Part 1 - Digital design foundations

### 1.1 Combinational and sequential logic

**Combinational logic** has no memory: its outputs depend only on its current
inputs (an adder, a multiplexer, an address decoder). In SystemVerilog it is
written with `assign` or `always_comb`.

**Sequential logic** remembers. The basic element is the **D flip-flop**: on
the rising edge of its clock it copies input D to output Q, and holds Q until
the next edge. Written with `always_ff @(posedge clk)`.

A synchronous design is "flip-flops, with clouds of combinational logic
between them, all clocked by the same clock". Each clock cycle, every flop
captures the result its input cloud computed during the previous cycle.

```
        +-------+    combinational     +-------+
  ...-->| D   Q |----> logic cloud ---->| D   Q |--> ...
        |  FF1  |                      |  FF2  |
 clk -->|>      |              clk  -->|>      |
        +-------+                      +-------+
```

### 1.2 Setup time, hold time, and why clocks have a maximum frequency

A flop needs its D input stable for a short **setup time** before the clock
edge and a **hold time** after it. Between FF1 and FF2 above:

- FF1's Q changes a **clock-to-Q delay** after the edge.
- The signal then travels through the logic cloud (**combinational delay**).
- It must arrive at FF2 at least **setup** before the next edge.

So the clock period must satisfy

```
T_clk >= t_clk-to-q + t_logic(max) + t_setup     (setup check)
t_clk-to-q + t_logic(min) >= t_hold               (hold check)
```

The longest such path is the **critical path**; it sets the maximum clock
frequency. Static timing analysis (Part 10) checks these two inequalities for
every path in the chip. Note what each depends on: setup depends on the clock
period, hold does not. A hold violation cannot be fixed by slowing the clock,
which is why hold is checked at the fast corner and fixed by adding delay.

### 1.3 Metastability

If D changes inside the setup/hold window, the flop may enter a
**metastable** state: its output hovers between 0 and 1 for an unpredictable
time before resolving. In a single-clock design, timing analysis guarantees
this never happens. When a signal arrives from a different clock (or from a
pin), nothing guarantees it, and you need a **synchroniser** (Part 7).

### 1.4 Resets

A reset puts every flop into a known state.

- **Synchronous reset**: checked only on a clock edge (`if (!rst_n)` inside an
  `always_ff @(posedge clk)`). Needs the clock running to take effect.
- **Asynchronous reset**: acts immediately (`always_ff @(posedge clk or
  negedge rst_n)`). Works with no clock.

The usual rule, used here, is **asynchronous assert, synchronous de-assert**
(`rtl/common/rst_sync.sv`): reset can hit at any time, but its release is
aligned to the clock, so all flops leave reset in the same cycle. Releasing
an async reset close to a clock edge is the same problem as metastability
(it's called a *recovery/removal* violation).

This project hit a real reset bug: PicoRV32 uses a **synchronous** reset. When
the PMU released reset while the clock was still gated, the CPU never saw a
clock edge during reset, so it was never reset and carried on from its old
program counter after wake. Fix: clock on before reset release (Part 6).

### 1.5 Finite state machines

A **finite state machine (FSM)** is a state register plus next-state logic.
`rtl/aon/pmu_fsm.sv` is written in the common two-block style:

- `always_comb` computes `nxt` (next state) and `adv` (advance now?) from the
  current `state` and the inputs.
- `always_ff` updates `state <= nxt` when `adv`, and **registers** every
  control output.

Registered outputs matter in power control: a combinational decode of the
state can glitch for a fraction of a cycle when several state bits change at
once, and a glitch on an isolation or power-switch enable is a real hardware
bug. Every PMU output is a flop.

### 1.6 Buses, handshakes and memory-mapped registers

The CPU talks to everything through a **bus**: address, write data, byte
strobes (`wstrb`, which bytes of a 32-bit word to write; all zero means
read), and a `valid` / `ready` handshake. A transfer happens in the cycle where
the master holds `valid` and the slave answers `ready`.

`rtl/common/bus_slave_ack.sv` is the one-wait-state slave every block shares:
`fire = valid & ~ready` marks the cycle the slave performs the access, and
`ready` follows one cycle later.

**Memory-mapped I/O** means peripherals look like memory: writing address
`0x2000_0000` does not store into RAM, it starts the accelerator. The top 4
address bits pick a region (`soc_pkg::RGN_*`); `cmp_top` decodes them and
routes the request. The full map is in `docs/spec.md`.

### 1.7 SystemVerilog constructs you will see

| Construct | Meaning | Example |
| --- | --- | --- |
| `logic` | 4-state variable (0, 1, X, Z) | everywhere |
| `parameter int N = 4` | compile-time constant, overridable per instance | `mac_array #(.N(N))` |
| `for (genvar ...)` | **generate** loop: makes N copies of hardware | PE grid in `mac_array.sv` |
| `localparam` in a package | shared constants | `rtl/pkg/soc_pkg.sv` |
| `` `ifdef X `` | compile-time switch | cell mapping in `iso_clamp0.sv` |
| `typedef enum` | named states | `st_t` in `pmu_fsm.sv` |

Note `soc_pkg::PS_IDLE` (package scope) instead of `import soc_pkg::*`: the
Yosys version used here cannot import inside a module, so the code always
writes the full name.

**Check yourself**

1. Why can't you fix a hold violation by lowering the clock frequency?
2. What happens if you release an asynchronous reset right at a clock edge?
3. Why must the PMU's outputs be flip-flops rather than decoded from the state?

---

## Part 2 - SoC architecture, RISC-V and firmware

### 2.1 What an SoC is

A **system on chip** puts a processor, memory, accelerators and peripherals
on one die, joined by a bus. Ours:

```
                 +---------------------------- PD_CMP ----------+
 host port ----->|  PicoRV32 CPU ---+--- boot ROM (4 KB)          |
                 |  (or host)       +--- MAC accelerator          |
                 |                  +--- to PD_MEM / PD_AON (bus) |
                 +------------------------------------------------+
     PD_MEM: scratch RAM (512 B), UART        PD_AON: PMU, timers, registers
```

There are two **bus masters** (things that start transfers): the CPU, or the
debug host port when `host_en = 1` (which holds the CPU in reset). The
testbench uses the host port to poke registers directly without firmware.

### 2.2 RISC-V and PicoRV32

**RISC-V** is an open instruction-set architecture (ISA). The name of a
variant lists its extensions:

- `RV32` - 32-bit registers and addresses
- `I` - the base integer instructions (add, load, store, branch...)
- `M` - multiply and divide
- `C` - compressed 16-bit encodings of common instructions (smaller code)

**PicoRV32** (`rtl/third_party/picorv32/picorv32.v`) is a small, simple
RV32IMC core: not fast (several cycles per instruction) but tiny and easy to
integrate. It exposes a simple valid/ready memory interface, which is why our
bus looks the way it does. Its features are chosen by parameters in
`cmp_top.sv`: compressed instructions and the multiplier are on, the divider
is off (`ENABLE_DIV = 0`) to save area, so the firmware avoids `/` and `%`
on variables (division by a constant power of two compiles to a shift). Its register file (`cpuregs`) has **no reset**,
which matters for power-off: after wake, the registers hold garbage, so
`fw/crt0.S` clears them.

### 2.3 How firmware gets into the chip

1. `fw/main.c` and `fw/crt0.S` are compiled for `rv32imc` by GCC.
2. `fw/link.ld` (the **linker script**) says where everything goes: code and
   constants in ROM at `0x0`, variables in RAM at `0x1000_0000`, the stack at
   the top of RAM.
3. `scripts/gen_rom.py` turns the binary into `rtl/cmp/boot_rom.sv`, a big
   `case` statement: address in, instruction word out. A case-statement ROM
   needs no memory-init file, so it works in every simulator and in
   synthesis (it becomes constant logic).
4. On reset, PicoRV32 starts fetching at address 0: `_start` in `crt0.S`,
   which clears registers, zeroes `.bss`, sets the stack pointer and calls
   `main`.

`crt0` is "C runtime zero": the few instructions that must run before C code
can run. There is no `.data` copy loop because the linker script forbids
initialised variables (they would need a ROM-to-RAM copy).

### 2.4 Cold boot and warm boot

When PD_CMP is powered off, the CPU loses everything. Waking up is therefore
a **reboot**: the CPU starts again at address 0. The firmware must find out
*why* it is booting. That is what `BOOT_REASON` in the always-on registers is
for: bit 0 says warm (a wake) or cold (power-on), bits [2:1] which state it
woke from, bits [6:4] which source woke it. `main.c` branches on it:

| Boot | Firmware does |
| --- | --- |
| cold | accelerator self-test, illegal-request checks, DVFS round trip, set up retained state, request IDLE with timer wake |
| from IDLE | check RAM survived (PD_MEM stayed on) and accelerator config came back (hardware retention); go to ACTIVE_L; request SLEEP with GPIO wake |
| from SLEEP | check AON scratch and config survived and the SoC is back at ACTIVE_L; run the accelerator; print `DONE PASS` |

This is exactly how real low-power MCUs work: a wake from deep sleep is a
reset with a "why" register.

### 2.5 Retention, and the `.noinit` section

Anything that must survive a power-down has to live in a domain that stays
on, or in special retention storage:

- Variables in `.noinit` (see `link.ld`) are in PD_MEM RAM and are never
  cleared by `crt0`, so they survive IDLE (PD_MEM on) but not SLEEP.
- The four AON scratch words survive both.
- The accelerator config is saved by hardware (Part 5.6).

**Check yourself**

1. Why does the CPU restart at address 0 after a wake?
2. Why does `crt0.S` clear the register file, when reset normally does that?
3. Where would you keep a counter that must survive SLEEP?

---

## Part 3 - The INT8 systolic accelerator

### 3.1 Why matrix multiply

Neural-network inference is mostly multiply-accumulate (MAC): a fully
connected layer is a matrix-vector product, and a convolution can be
rearranged into a matrix-matrix product. An accelerator that does
`C = A x B` fast and cheaply covers most of the work. Our block computes

```
C[i][j] = sum over k = 0..K-1 of A[i][k] * B[k][j]      (N x K times K x N)
```

with `1 <= K <= N` and optional **ReLU** (`max(0, x)`, the most common
activation function).

### 3.2 INT8 quantisation and INT32 accumulation

Edge inference uses 8-bit integers instead of 32-bit floats: four times less
memory and bandwidth, and an 8x8 multiplier is far smaller and lower power
than a float multiplier. Values are **quantised**: real value ~ scale x
(integer - zero point), with the scale chosen per tensor.

The products must accumulate in a wider register or they overflow:

- largest product magnitude: (-128) x (-128) = 16,384 (needs 16 bits)
- sum of K <= 8 of them: at most 131,072, far inside an INT32

So: INT8 x INT8 -> 16-bit product -> INT32 accumulator, as in `mac_pe.sv`.
Real NPUs do the same, then **requantise** the INT32 result back to INT8 for
the next layer (not implemented here).

### 3.3 Systolic arrays

A naive design reads every operand from memory for every multiply. A
**systolic array** is a grid of processing elements (PEs) where operands
flow from neighbour to neighbour, so each value read from the buffer is used
N times as it travels. Data "pulses" through the grid like blood, hence the
name (H.T. Kung, 1978; Google's TPU is the famous large example).

Our PE (`rtl/cmp/mac_pe.sv`) does three things each cycle:

```
acc   <= acc + a_in * b_in      // multiply-accumulate
a_out <= a_in                   // pass A to the right
b_out <= b_in                   // pass B down
```

`rtl/cmp/mac_array.sv` wires N x N of them: A values enter from the left of
each row and move right; B values enter at the top of each column and move
down.

**Dataflows.** The name says what stays still:

| Dataflow | Stays in each PE | Moves |
| --- | --- | --- |
| **output-stationary** (ours) | the partial sum C[i][j] | A and B |
| weight-stationary (TPU) | one weight B[k][j] | A and partial sums |
| row-stationary (Eyeriss) | a row of filter weights | mixed |

Output-stationary is the simplest to read out: when the job ends, PE(i,j)
holds exactly C[i][j].

### 3.4 Skewing: making the right pairs meet

PE(i,j) must see A[i][k] and B[k][j] **in the same cycle**, for every k. A
value injected into row i takes j cycles to reach column j; a value injected
into column j takes i cycles to reach row i. So the feed is **skewed**:

- row i gets A[i][k] at cycle t = i + k
- column j gets B[k][j] at cycle t = j + k

Then A[i][k] reaches PE(i,j) at (i + k) + j and B[k][j] reaches it at
(j + k) + i: the same cycle, i + j + k. Worked example, N = 2, K = 2:

```
cycle t:          0          1                    2
row 0 input:   A00        A01                   0
row 1 input:   0          A10                   A11
col 0 input:   B00        B10                   0
col 1 input:   0          B01                   B11

PE(0,0) gets A00*B00 at t=0, A01*B10 at t=1          -> C00
PE(0,1) gets A00*B01 at t=1, A01*B11 at t=2          -> C01
PE(1,0) gets A10*B00 at t=1, A11*B10 at t=2          -> C10
PE(1,1) gets A10*B01 at t=2, A11*B11 at t=3          -> C11
```

Outside `0 <= t - i < K` the feed is zero, so those cycles add nothing. The
skew logic is the `always_comb` "operand feed" block in `mac_accel.sv`.

### 3.5 Latency: why a job takes K + 2N + 1 cycles

The last useful product reaches the last PE, (N-1, N-1), at
t = (N-1) + (N-1) + (K-1) = K + 2N - 3. Counting the controller states in
`mac_accel.sv`:

| State | Cycles |
| --- | --- |
| start (write to CTRL) | 1 |
| `S_CLR`: clear accumulators | 1 |
| `S_RUN`: t = 0 ... K + 2N - 3 | K + 2N - 2 |
| `S_LATCH`: copy results to C, apply ReLU | 1 |
| **total** | **K + 2N + 1** |

13 cycles at N = K = 4. The tests check `ACC_CYCLES` against this formula
every job: a timing change in the array would be caught immediately.

**Utilisation** is the fraction of PE-cycles doing useful work:
N x N x K useful MACs over N x N x (K + 2N - 2) PE-cycles. For a single small
job most cycles are spent filling and draining the pipeline, which is why
real accelerators stream many jobs back to back (out of scope here).

### 3.6 Clock-gating the array

The array runs on its own gated clock (`icg u_icg` in `mac_accel.sv`), enabled
only in `S_CLR` and `S_RUN`. When idle, the N x N x (32 + 8 + 8) flops get no
clock edges and burn no dynamic power. `tb/sva/mac_sva.sv` asserts the clock
enable is low whenever the accelerator is idle.

### 3.7 Relation to NVDLA and real NPUs

NVIDIA's NVDLA has a convolution core built from MAC cells fed by buffers,
plus separate units for activation, pooling and normalisation. Arm's
Ethos-U55 is a microNPU with 32 to 256 MACs beside a Cortex-M CPU. Ours is a
tiny version of the same split: a CPU for control, a MAC array for the
arithmetic. See `docs/use_case.md`.

**Check yourself**

1. In an output-stationary array, what stays in each PE?
2. Why must row i's inputs be delayed by i cycles?
3. Why is the accumulator 32 bits when the operands are 8 bits?
4. Derive the cycle count for N = 8, K = 8.

---

## Part 4 - Where power goes

### 4.1 Dynamic power

Every time a node switches from 0 to 1, its capacitance C charges from the
supply. Averaged:

```
P_dynamic = alpha x C x V^2 x f
```

- **alpha** (activity factor): fraction of cycles a node switches
- **C**: switched capacitance (gates, wires)
- **V**: supply voltage - **squared**, so the strongest lever
- **f**: clock frequency

Ways to cut it: reduce alpha (clock gating, operand isolation), reduce C
(smaller design, shorter wires), reduce V and f (DVFS). Clock nets switch
every cycle (alpha = 1 for the clock itself), so the clock tree alone is often
30-40 % of dynamic power in a chip, which is why clock gating pays.

There is also **short-circuit power**: during a transition both the pull-up
and pull-down transistors conduct briefly. It grows with slow input edges and
is usually reported with dynamic ("internal") power.

### 4.2 Leakage (static) power

A transistor that is "off" still conducts a little. Leakage flows all the
time, even with the clock stopped:

- **Subthreshold leakage**: current below the threshold voltage Vt. It falls
  exponentially as Vt rises: at best about 10x less per 60 mV more Vt at room
  temperature (the subthreshold swing), more in practice. It also rises
  steeply with **temperature**.
- **Gate leakage**: tunnelling through very thin gate oxide (significant in
  advanced nodes, small in Sky130's 130 nm).
- **Junction leakage**: reverse-biased diodes.

Leakage is roughly proportional to the number of transistors that are
powered. Clock gating does nothing for it. The only ways to cut it are to
remove the supply (**power gating**), use high-Vt cells where speed is not
needed (**multi-Vt**), or lower the voltage.

### 4.3 Energy, power and duty cycle

Battery life depends on **energy**, not power. An edge device that is active
a fraction D of the time:

```
P_average = D x P_active + (1 - D) x P_sleep
```

At 1 % duty cycle, sleep is 99 % of the time. If active power is 10 mW and
sleep power 100 uW, average is 0.10 + 0.099 = about 0.2 mW: half of all energy
goes to sleeping. Cutting sleep leakage then roughly doubles battery life,
which is the whole argument for this project's power gating
(`docs/use_case.md`).

For DVFS the useful quantity is **energy per job**:

```
E_job ~ C x V^2 (dynamic, per operation)  +  P_leak x t_job
```

Lowering V from 1.80 to 1.50 V cuts the dynamic part by 1 - (1.5/1.8)^2, about
31 %, but the job takes twice as long at f/2, so leakage energy for the job
doubles. Which wins depends on the leakage share: this is "race to idle" (run
fast, then power off) versus "slow and low", and real chips decide it per
workload.

**Check yourself**

1. Which term in P_dynamic does clock gating reduce? Which does DVFS reduce?
2. Why does clock gating not help leakage?
3. When does running slower at lower voltage cost *more* energy per job?

---

## Part 5 - Low-power techniques

From cheapest to most involved. Each one is in this design.

| Technique | Cuts | Cost | Here |
| --- | --- | --- | --- |
| clock gating | dynamic power of idle logic | one cell per gated group | `icg.sv`: PD_CMP, PD_MEM, MAC array |
| operand isolation | glitching in receivers | AND gates | `cmp_top.sv` payload gating |
| multi-Vt | leakage on non-critical paths | library choice | ASAP7 study in `flow/asap7` |
| power gating | leakage of a whole domain | switches, isolation, sequencing, retention | PD_CMP and PD_MEM |
| DVFS | dynamic energy (V^2) | regulator, clock switch, level shifters | PD_CMP: OPP-H / OPP-L |

### 5.1 Power domains

A **power domain** is a group of logic that shares one supply and is switched
or scaled together. Ours:

| Domain | Supply | What happens to it |
| --- | --- | --- |
| PD_AON (always-on) | 1.80 V | never off: it is the part that must be awake to wake everything else |
| PD_CMP (compute) | 1.80 V or ~1.50 V | DVFS, switched off in IDLE and SLEEP |
| PD_MEM (memory) | 1.80 V | switched off in SLEEP only |

**Power states** are the legal combinations: ACTIVE_H, ACTIVE_L, IDLE,
SLEEP. One combination is deliberately illegal: **PD_CMP on with PD_MEM
off**. The CPU would fetch from or write to a dead RAM. The PMU always powers
MEM up before CMP and down after it; the formal proof shows the illegal state
is unreachable.

### 5.2 Clock gating

To stop a block's dynamic power, stop its clock. You cannot just AND the
clock with an enable:

```
clk     _|‾|_|‾|_|‾|_
en      ___|‾‾‾‾‾‾‾      <- en changes while clk is high
clk&en  ___|‾|_|‾|_      <- a short "runt" pulse at the first edge: a glitch
```

A runt pulse may clock some flops and not others. An **integrated clock
gate (ICG)** puts a latch on the enable that is transparent only while the
clock is low, so the enable can only change while the AND output is already
low:

```
          +-------+
 en ----->| D   Q |---+
          | latch |   AND ---> gclk
 clk -o-->| G     |   |
     |    +-------+   |
     +----------------+
```

Sky130's ICG is `sky130_fd_sc_hd__dlclkp_1` (`icg.sv` maps to it under
`SKY130_CELLS`). The behavioural model in `icg.sv` uses a falling-edge flop
instead of a latch: equivalent for enables launched by rising-edge flops, and
it simulates in Verilator, which cannot settle latch loops in a clock path.
`test_en` forces gates open during manufacturing test.

### 5.3 Operand isolation

Even when a receiver ignores its inputs, toggling inputs make its
combinational logic switch. `cmp_top.sv` forces address and data to zero
unless a real access is happening (`mem_payload = mem_valid_c ? ... : '0`).
It costs a few AND gates and saves switching in PD_MEM and PD_AON every idle
cycle. (It also keeps the CPU's undefined post-reset bus from spreading X in
simulation.)

### 5.4 Power gating

To remove leakage, remove the supply. A **power switch** (header: a PMOS
between the real supply and the domain's virtual supply; or footer: an NMOS
on ground) is turned off by the PMU. Practical points:

- **Rush current.** Turning on a big domain at once draws a large current
  spike that can droop the always-on supply. Real switch networks turn on in
  stages (a weak chain first, then the strong one) and report back with an
  **acknowledge** when the domain is fully up. Our `sw_en_* / sw_ack_*`
  interface models exactly that handshake; `tb/models/pwr_switch_model.sv`
  answers after a delay.
- **Everything inside is lost.** Flops and memories in an unpowered domain
  have no defined value. After power-up they are random until reset.
- **The outputs float.** An unpowered domain's outputs drift to undefined
  voltages. That is the next problem.

Sky130 HD has no power-switch cell, so the switches are off-chip in this
project (modelled), and each switched domain gets its own supply pin in the
experimental multi-domain layout.

### 5.5 Isolation

An unpowered domain's output wire floats somewhere between 0 and 1. In the
powered receiver, a gate input at mid-rail turns on **both** its pull-up and
pull-down transistors: a short-circuit "crowbar" current, plus random logic
values. In simulation we represent the floating value as **X**.

An **isolation cell** in the receiving domain clamps the signal to a fixed
value while the source is off:

| Wrapper | Function | Sky130 cell | Clamp |
| --- | --- | --- | --- |
| `iso_clamp0` | `q = iso ? 0 : d` | `lpflow_isobufsrc_1` (X = A & !SLEEP) | 0 |
| `iso_clamp1` | `q = iso ? 1 : d` | `lpflow_inputiso1p_1` (X = A \| SLEEP) | 1 |

Rules this design follows (from `docs/spec.md`):

- **Placement: in the receiving domain**, powered by the receiver's supply.
  An isolation cell inside the dead domain would be dead too.
- **Clamp value = the inactive level.** `valid` and `ready` clamp to 0 so the
  receiver sees "no request". The UART line clamps to **1** because an idle
  UART line is high; clamping it low would look like a start bit.
- **Isolate before power-off, release after power-good and restore.**
- **Signals from an always-on domain need no isolation** (the source never
  turns off).

`scripts/check_crossings.py` verifies structurally that every bit crossing a
boundary goes through the right cell, so nobody can add an unprotected
signal later without CI failing.

### 5.6 Retention

Some state must survive power-off. Two ways:

1. **Retention flops** ("balloon" latches): each flop has a small extra latch
   on the always-on supply. `save` copies into it before power-off,
   `restore` copies back after power-up. Needs special cells.
2. **Shadow register** (what we do, since Sky130 HD has no retention flops):
   a register in PD_AON (`ret_cfg_shadow` in `aon_top.sv`) is loaded from
   the accelerator's config register on `cmp_save`, and the accelerator
   reloads from it on `restore`.

Because the shadow sits on the other side of the domain boundary, its input
passes through the isolation cell. So **save must come before isolate**:
after isolation the shadow would read the clamp value (0). With in-place
retention flops the order could be different; `upf/soc.upf` describes the
intent with `set_retention` either way.

Choose what to retain carefully: retention costs area and always-on leakage.
Here only the 9-bit accelerator config (K and ReLU) is hardware-retained;
the operand buffers and CPU registers are rebuilt by firmware.

### 5.7 DVFS and level shifting

**DVFS** (dynamic voltage and frequency scaling) runs a domain at a lower
voltage when it doesn't need full speed. Gates get slower as voltage drops
(roughly, delay ~ V / (V - Vt)^a with a between 1 and 2, the "alpha-power
law"), so a lower voltage needs a lower frequency. A legal (voltage,
frequency) pair is an **operating performance point (OPP)**:

| OPP | VDD_CMP | clk_sys |
| --- | --- | --- |
| OPP-H (ACTIVE_H) | 1.80 V | clk_in (50 MHz) |
| OPP-L (ACTIVE_L) | ~1.50 V | clk_in / 2 |

The **ordering rule** is the key idea: the clock must never be faster than
the present voltage supports, even for one cycle.

- **Going up:** raise the voltage, wait until the regulator says it has
  settled (`vdd_ok`), then raise the frequency.
- **Going down:** lower the frequency first, then the voltage.

The regulator is off-chip; `tb/models/regulator_model.sv` holds `vdd_ok` low
for a settling time after every change. The frequency changes through a
glitch-free clock switch (Part 7.5).

**Level shifters.** A 1.50 V logic "1" driving a 1.80 V gate is a weak high:
the receiving PMOS is not fully off, so it leaks (crowbar current) and the
noise margin is poor. A **low-to-high level shifter**
(`lpflow_lsbuf_lh_isowell_4`, wrapper `ls_lh.sv`) restores full swing. It has
two supplies: `LOWLVPWR` for the input side and `VPWR` for the output side.
Going the other way (1.80 V into 1.50 V logic) is safe in this process
without a shifter. Since only PD_CMP scales, only signals **leaving** PD_CMP
get level shifters.

When a signal needs both, the order is **level shifter, then isolation**
(both in the receiver). The isolation cell then sits fully in the receiver's
supply and clamps whatever the shifter outputs, including the X a shifter
produces when its low-side supply is off. The gate-level simulation shows
this happening: with VDD_CMP off, the shifter outputs X and the isolation
cell clamps it to 0.

**Check yourself**

1. Why is a plain AND gate a bad clock gate?
2. Why does the UART line clamp to 1 and not 0?
3. Why must save happen before isolation in this design?
4. Why does the voltage go up before the frequency?
5. Why do signals into PD_CMP not need level shifters?

---

## Part 6 - The PMU and power sequencing

`rtl/aon/pmu_fsm.sv` is the brain of the always-on domain. Software writes a
target state to `PMU_CTRL`; the PMU checks it is legal, then walks a fixed
**sequence** of steps. Each step changes one registered output, waits at
least `SEQ_CFG` cycles (`cnt`), and where the step has an acknowledge, waits
for it too.

### 6.1 Accepting or refusing a request

A request is accepted only if the PMU is idle (`S_STABLE`), the SoC is
active, the target is 0-3 and different from the current state, and, for
IDLE or SLEEP, at least one wake source is enabled. Powering down with no way
to wake would brick the chip until a power cycle. A request for the current
state is a silent no-op; anything else invalid sets `PMU_STATUS.err`.

### 6.2 The sequences, step by step

**Power-down of PD_CMP** (`S_C_*` states):

| Step | Output change | Why it is here |
| --- | --- | --- |
| `S_C_REQ` | `cmp_pwr_req = 1`, wait `cmp_pwr_ack` | **quiesce**: the bus fabric stops new remote transfers once none is in flight (the *fence* in `cmp_top.sv`) and the accelerator must be idle, so no transfer is cut in half. Also arms the wake timer. |
| `S_C_CLK` | `cmp_clk_en = 0` | stop activity before anything else changes |
| `S_C_SAVE` | `cmp_save` pulse | copy the accelerator config to the AON shadow (before isolation, see 5.6) |
| `S_C_ISO` | `cmp_iso = 1` | receivers now see clamp values |
| `S_C_RST` | `cmp_rst_n = 0` | known state for when power returns |
| `S_C_OFF` | `cmp_sw_en = 0`, wait `cmp_sw_ack = 0` | power actually removed; state becomes IDLE |

For SLEEP, PD_MEM follows: clock off, isolate, reset, switch off
(`S_M_*`).

**Power-up** after a wake, MEM first if it was off:

| Step | Output change | Why |
| --- | --- | --- |
| `S_M_ON` / `S_C_ON` | switch on, wait ack | power must be stable first |
| `S_*_CLKON` | clock on | **before** reset release: PicoRV32's synchronous reset needs edges |
| `S_*_RSTREL` | reset released | the domain starts from a clean state |
| `S_C_RESTORE` | `cmp_restore` pulse | config comes back from the shadow |
| `S_*_ISOREL` | isolation off | only now are the domain's outputs valid; state becomes ACTIVE at the old OPP |

**DVFS** (`S_DV_*`): H to L is frequency low then voltage low; L to H is
voltage high (wait `vdd_ok`) then frequency high (wait for the clock switch
to confirm).

Read the full sequence list in the comment at the top of `pmu_fsm.sv` while
looking at the `case (state)` block: each row of the tables above is one
line there.

### 6.3 Wake handling, and races

Wake sources: the 32 kHz timer, the GPIO pin, the host pin, each enabled by a
bit of `WAKE_MASK`. Two subtle rules:

- **A wake that arrives during the power-down sequence is not lost.** It is
  latched in `wake_pend`; the sequence completes (you cannot abort halfway
  through isolation), then the PMU immediately wakes. `test_wake_race` fires
  a wake at every cycle offset 0..120 after the request (in the full
  regression; `--quick` sweeps 0..29) to prove it.
- **Wake events count from the start of a power-down.** An old event from
  before the request does not cause a spurious wake.

On wake the PMU records `wake_src` and `wake_from`, which become
`BOOT_REASON` for the firmware.

### 6.4 Why one fixed sequencer

It would be tempting to let software toggle isolation and switches
directly. Real SoCs don't: a firmware bug could power off a domain without
isolating it. A hardware sequencer with fixed ordering can be **proved**
correct once (Part 9.7) and then cannot be misused.

**Check yourself**

1. What does "quiesce" mean and what breaks without it?
2. A GPIO wake arrives between `S_C_ISO` and `S_C_RST`. What happens?
3. Why is the IDLE request refused when `WAKE_MASK = 0`?

---

## Part 7 - Clocks, resets and clock-domain crossing (CDC)

### 7.1 Clock domains in this chip

| Clock | Drives | Notes |
| --- | --- | --- |
| `clk_in` | root | 50 MHz reference |
| `clk_sys` | PD_AON | `clk_in` or `clk_in/2` via the glitch-free switch |
| `clk_cmp`, `clk_mem` | PD_CMP, PD_MEM | gated copies of `clk_sys` (same domain, just gated) |
| `mac_clk` | the MAC array | gated copy of `clk_cmp` |
| `clk_32k` | the wake-timer counter only | **asynchronous** to everything else |

Gated copies of one clock are still one clock domain: the bus between
domains is synchronous, so no CDC logic is needed on it. That was a
deliberate design choice (`docs/spec.md`). The real asynchronous crossings
are the wake timer, the wake pins, the clock-switch status, and the
handshakes from the regulator (`vdd_ok`) and power switches (`sw_ack_*`).
Those last ones were first wired straight into the PMU, because the
simulation models happen to answer on `clk_sys`; corner STA flagged them
(they were being timed as synchronous inputs), and v1.0 added the missing
synchronisers. Real analog blocks have no clock relationship to your logic:
always synchronise their outputs.

### 7.2 The two-flop synchroniser

A signal from another clock domain can change at any time relative to our
clock, so the first flop that samples it may go metastable. The fix
(`sync_2ff.sv`) is a second flop: the first flop has a whole clock period to
resolve before the second samples it. The probability that metastability
lasts that long falls exponentially:

```
MTBF = e^(t_resolve / tau) / (T_0 x f_clk x f_data)
```

where tau and T_0 are flop constants. One extra period of resolve time
typically turns "fails every few minutes" into "fails once in the age of the
universe". Rules:

- Only **single bits** (or bits that never change together) go through a
  2FF synchroniser. A multi-bit bus synchronised bit by bit can arrive with
  some bits old and some new.
- No logic between the two flops.

### 7.3 Moving an event across: the toggle synchroniser

A one-cycle pulse in a fast domain can be missed entirely by a slow domain.
Instead, the source **flips a level** (`tgl`) once per event; the level is
held, so it is safely synchronised, and the destination turns each change
into a one-cycle pulse (`pulse_sync.sv`: `pulse = s ^ s_d`). The wake timer
uses this in both directions: `arm_tgl` from clk_sys to clk_32k, and
`match_tgl` back.

### 7.4 Quasi-static signals

The 24-bit timer period crosses into clk_32k without a synchroniser. That is
legal only because it is **quasi-static**: software writes it long before
the arm toggle arrives on the other side, so it is stable whenever it is
sampled. This kind of argument must be written down (it is, in
`wake_timer.sv` and `docs/spec.md`), because a CDC tool cannot see it.

### 7.5 Glitch-free clock switching

Switching `clk_sys` between `clk_in` and `clk_in/2` with a plain mux can
produce a runt pulse. `clk_switch.sv` is the classic **break-before-make**
switch: each side has its enable flops clocked by its own clock; one side
only enables after the other side has disabled itself on its own falling
edge. For a few cycles neither clock drives the output (it stays low), then
the new one takes over cleanly. `sel0_q / sel1_q` report which clock is
really driving, synchronised to give the PMU its `freq_*_ack`.

### 7.6 Case study: the stale-expiry bug (fixed in v0.2)

The original wake timer had a race. Sequence of events:

1. The timer expires; `match_tgl` flips in the 32 kHz domain and starts
   crossing to clk_sys (two flops, plus a 32 kHz period of latency).
2. Meanwhile the SoC woke from another source and the firmware asks for a
   new power-down, which re-arms the timer.
3. The old expiry finishes crossing and is reported as a wake event for the
   **new** power-down, which wakes immediately.

Fix: the 32 kHz side echoes back the arm toggle it has seen (`arm_d`), also
through a synchroniser. An expiry counts only while that echo equals the
current `arm_tgl`, which means it belongs to the latest arming. Why this is
safe: on the 32 kHz side, `arm_d` changes before any expiry of the new
arming can happen, and both signals cross through identical two-flop
synchronisers, so the echo can never arrive after the new arming's expiry.

The unit test `tb/unit/tb_wake_timer.sv` re-arms exactly on an expiry
(`@(dut.match_tgl)`): on the old RTL it delivers the stale event, on the new
one it doesn't. A good CDC bug: impossible to see in a normal test, obvious
once you aim a test at the window.

### 7.7 Reset per domain

`por_n` (power-on reset) is synchronised separately into clk_sys and clk_32k
(`rst_sync`). Each switched domain's reset is the AND of the system reset and
the PMU's domain reset (`clk_rst_ctrl.sv`).

**Check yourself**

1. Why is the bus between PD_CMP and PD_MEM not a CDC?
2. Why can't you synchronise a 24-bit counter value with 24 two-flop
   synchronisers?
3. Explain the stale-expiry bug in three sentences.

---

## Part 8 - Power intent: UPF (IEEE 1801)

### 8.1 Why a separate power-intent file

RTL describes logic. It doesn't say which logic sits on which supply, where
isolation goes, or what is retained. In industry that information lives in a
**UPF** file (Unified Power Format, IEEE 1801), written once and read by
every tool: power-aware simulators corrupt registers in powered-off domains,
synthesis inserts isolation and level-shifter cells, place and route builds
the separate power grids, and sign-off checks it all against the netlist.

In this project the protection cells are written into the RTL by hand
(`iso_clamp0`, `ls_lh`...), because the open-source tools only partly read
UPF. `upf/soc.upf` describes the same intent formally, so it can be checked
with a commercial tool later and so you learn the language.

### 8.2 Reading `upf/soc.upf`

| Command | What it says |
| --- | --- |
| `create_power_domain PD_CMP -elements {u_cmp}` | instance `u_cmp` and everything below it is one domain |
| `create_supply_port / create_supply_net` | the supply pins and wires (`VDD_CMP_EXT` from the regulator, `VDD_CMP` after the switch) |
| `create_supply_set SS_CMP -function {power VDD_CMP} -function {ground VSS}` | a named power/ground pair |
| `associate_supply_set SS_CMP -handle PD_CMP.primary` | the domain's main supply |
| `create_power_switch SW_CMP ... -control_port {en u_aon/u_pmu/cmp_sw_en} -ack_port ...` | the switch, its control and acknowledge |
| `set_isolation ISO_CMP_OUT -domain PD_CMP -applies_to outputs -clamp_value 0 -isolation_signal u_aon/u_pmu/cmp_iso -location parent` | clamp every output of PD_CMP to 0 when `cmp_iso` is high, with the cell placed in the parent (receiving) side |
| `set_isolation ISO_MEM_UART ... -clamp_value 1` | the UART exception |
| `set_level_shifter LS_CMP_OUT -domain PD_CMP -applies_to outputs -rule low_to_high` | shifters on PD_CMP outputs |
| `set_retention RET_ACC_CFG -elements {u_cmp/u_acc/cfg_q} -save_signal ... -restore_signal ...` | retain the accelerator config |
| `add_power_state SS_CMP -state OFF {-supply_expr {power == OFF} -simstate CORRUPT}` | the supply states; `CORRUPT` tells a power-aware simulator to set everything in the domain to X |
| `add_power_state PD_AON -state IDLE {-logic_expr {SS_CMP == OFF && SS_MEM == ON}}` | the legal system states ACTIVE_H ... SLEEP; CMP on with MEM off is simply not listed, so it is illegal |

`upf/soc_openroad.upf` is the subset OpenROAD understands, used by the
experimental multi-domain layout.

**Check yourself**

1. Which tool would insert isolation cells from UPF in a commercial flow?
2. What does `-location parent` mean, and why parent?

---

## Part 9 - Verification

Design is maybe a third of chip work; verification is more. The question
verification answers is "how do we know it works, in every situation that
can occur?" No single method answers it, so this project stacks several,
each catching bugs the others miss.

### 9.1 The verification plan

Start from the spec, list every feature and every rule, and decide how each
is checked. `docs/verification.md` is the plan; every table row there maps
to a test, an assertion or a proof. A typical plan item: "Isolation is
active whenever a domain's switch is off" -> assertion `a_cmp_off_iso` in
`tb/sva/pmu_sva.sv`, property in `formal/pmu_formal.sv`, per-cycle check in
`tb/power` and `tb/gls`.

### 9.2 Directed versus constrained-random testing

- **Directed test**: you write the exact stimulus ("write these two
  matrices, start, compare"). Good for bring-up and specific corners. Only
  finds bugs you thought of.
- **Constrained-random test**: you describe the *space* of legal stimulus
  and let the simulator pick. Each seed explores different cases. A
  **reference model** predicts the correct answer, a **scoreboard**
  compares. Finds bugs you didn't think of.

The class-based environment (`tb/env/tb_pkg.sv`) is constrained-random;
the firmware test, the unit test and the gate-level test are directed.

### 9.3 SystemVerilog for verification: classes

Testbench code is software, written with object-oriented SystemVerilog:

| Concept | Meaning | In `tb_pkg.sv` |
| --- | --- | --- |
| `class` | a type with data and methods | `mat_job`, `scoreboard` |
| object, handle | `new()` makes an object; a variable holds a handle (reference) to it | `mat_job j = new(n);` |
| `virtual interface` | a handle to the pins of the DUT, so a class can drive them | `virtual soc_if vif` in `host_driver` |
| `task` vs `function` | tasks may wait for time (`@(negedge clk)`), functions may not | `write32` is a task |
| inheritance | `class test_x extends base_test` reuses the helpers | 7 tests |
| `virtual task body()` | polymorphism: `base_test` handle, test-specific behaviour | `t.body()` in `tb_soc.sv` |
| factory | pick the class by name at run time | `create_test(name, ...)`, `+TEST=` |

The **driver** (`host_driver`) turns "write 0x1 to address X" into pin wiggles
on the debug host port, always driving and sampling on the falling clock edge
so it never races the DUT's rising-edge flops.

### 9.4 Randomisation and constraints

```systemverilog
rand bit [3:0] k;
constraint c_k { k inside {[1:8]}; k <= n; }
```

`randomize()` picks values satisfying every constraint. `post_randomize()`
then derives the operands from a seed and computes the expected result, so a
failing job can be reproduced from `(seed, k, relu, corners)` alone.
Constraints can also **bias** values: `corners dist {1 := 1, 0 := 3}` picks
the corner-value mode a quarter of the time, so -128, -1, 0, 1, 127 (where
arithmetic bugs live) appear far more often than they would uniformly.

Verilator 5.0x ignores constraint blocks, so under `` `ifdef VERILATOR `` each
class maps its random values into the legal space in `fixup()`. xsim solves
the constraints properly.

### 9.5 Reference model and scoreboard

- `mat_job.post_randomize()` is the accelerator's reference model: plain
  nested loops computing C.
- `pmu_model` predicts what the PMU will do with a request: accepted,
  refused with error, or no-op, and the resulting state.
- `scoreboard.check(ok, msg)` counts checks and errors. A test passes only
  with zero errors **and** a non-zero number of checks (a test that checked
  nothing is not a pass).

### 9.6 Coverage

Passing tests prove nothing about what was *not* exercised. Coverage
measures what was.

- **Code coverage** (collected by the simulator): which lines, branches,
  conditions and toggles were exercised. 100 % code coverage is necessary,
  not sufficient.
- **Functional coverage** (written by you): did the scenarios in the plan
  happen? `soc_cov` in `tb_pkg.sv` has covergroups such as state transitions
  (from x to), wake source x state, and K x ReLU. A **cross** covers
  combinations. Bins that are never hit tell you what the random tests miss.

Coverage closure is the loop: run, look at holes, adjust constraints or add
tests, repeat. Verilator 5.0x has no covergroups; xsim does
(`run.py regress` collects both kinds there into `build/coverage_n*`).

### 9.7 Assertions (SVA)

An assertion states a rule that must always hold and is checked on every
cycle of every test, so it catches a bug wherever it happens, not only where
a test happens to look.

```systemverilog
a_cmp_off_iso : assert property (@(posedge clk) disable iff (!rst_n)
                                 !cmp_sw_en |-> cmp_iso);
```

Read it as: "on every rising clock edge, except during reset, if the PD_CMP
switch is off then isolation is on." Parts:

| Piece | Meaning |
| --- | --- |
| `@(posedge clk)` | sampling clock |
| `disable iff (!rst_n)` | don't check during reset |
| `a \|-> b` | implication, same cycle: whenever `a`, also `b` |
| `a \|=> b` | next cycle |
| `$fell(x)`, `$rose(x)` | x went 1 -> 0 / 0 -> 1 since the last sample |
| `##[1:5000]` | between 1 and 5000 cycles later |
| `cover property` | "this sequence happened at least once" (reachability) |

**Immediate** assertions (`assert (x)` inside procedural code) check at one
point in time; **concurrent** ones (`assert property`) check on every clock.
The `bind` statement attaches an assertion module to every instance of a
design module without editing the RTL (`bind pmu_fsm pmu_sva ...`), which
keeps checkers separate from the design.

This repo wraps the clock and disable in a `` `CHK `` macro, because
Verilator does not support `default disable iff`.

### 9.8 Four-state logic, X, and power-aware simulation

Simulators have four values: 0, 1, Z (undriven) and **X** (unknown). An X
appears from an uninitialised flop, a conflict, or, in our power model, an
unpowered domain. X propagates through logic: `X & 1 = X`, `X & 0 = 0`.

**Power-aware RTL simulation** (`tb/power`, `+define+PWR_SIM`): `pd_out`
drives X from a domain whose power-good is low, and memories plus the CPU
register file are corrupted (set to X) at power-off. If isolation is missing
anywhere, X leaks into a powered domain and the checks see it. Two-state
simulators (Verilator) cannot do this, which is why the power test needs
xsim or Icarus.

**X-pessimism and X-optimism**: `if (x)` with x = X takes the else branch
in simulation (optimistic: hides the X), while real hardware might do either.
Our checks look for X directly on outputs (`HAS_X` macro using reduction XOR)
rather than trusting branch behaviour.

### 9.9 Checking the checkers: fault injection and mutation testing

A testbench that never fails is suspicious: maybe its checks are dead. So:

- **Fault injection**: `run.py power --fault` rebuilds the design with
  `FAULT_NO_ISO` (isolation removed). The power test **must fail**; it does,
  with over a thousand errors.
- **Mutation testing**: deliberately plant bugs (isolation never set,
  frequency raised before voltage, wake skipping PD_MEM, no restore, wrong
  ReLU, wake lost mid power-down) and confirm each is caught. Results are in
  `docs/verification.md`.

This is how you convince a reviewer the verification has teeth.

### 9.10 Formal verification

Simulation checks the cases you run. **Formal verification** mathematically
checks **all** possible input sequences against a property.

- **Harness** (`formal/pmu_formal.sv`): the PMU with every input left free
  (the solver picks any value each cycle), plus `assume` statements for what
  the environment really guarantees (switches only acknowledge after being
  enabled, etc.). Too few assumptions give false failures; too many hide real
  bugs (**over-constraining**).
- **BMC (bounded model checking)**: "no property fails in the first N
  cycles from reset". Fast at finding bugs; not a proof beyond N.
- **Induction / IC3 (PDR)**: proves a property for **all** time.
  IC3/PDR (`abc pdr`) builds inductive invariants automatically: facts that
  hold in the initial state and are preserved by every transition. "Property
  proved" from `abc pdr` means unbounded.
- **Cover**: "this state is reachable". If a cover is unreachable, the
  assumptions are too strong, and a proof could be vacuous ("true because
  nothing can happen"). `formal/pmu.sby` has a cover task for this.

The flow used in CI: Yosys reads the harness, converts it to an AIGER
circuit (`formal/pdr.ys`), and ABC's PDR engine proves the 14 assertions.
Formal is ideal for control logic like a PMU (small state, nasty timing
interleavings); it scales badly to wide data paths like the MAC array, which
is why the array is checked by simulation instead.

### 9.11 Structural checks, lint and elaboration

- **Lint** (`run.py lint`, Verilator `--lint-only -Wall`): width mismatches,
  unused signals, latches. It caught two real bugs here (ReLU bit and
  BOOT_REASON fields in the wrong positions).
- **Crossing check** (`scripts/check_crossings.py`): reads the elaborated
  netlist and proves every bit entering a domain goes through the expected
  cell first. A cheap, static version of what commercial "low-power static
  checkers" do from UPF.
- **Strict elaboration** (`run.py elab`, slang): compiles every testbench
  configuration, including code only xsim runs (covergroups, constraints,
  `##` sequences), so syntax errors in those paths show up in CI.

### 9.12 Gate-level simulation (GLS)

After synthesis the design is a netlist of library cells. GLS simulates that
netlist. It catches what RTL simulation can't: synthesis/RTL mismatches,
missing resets, and, with **power-aware cell models**, isolation that
synthesis broke or optimised away.

Here (`run.py gls`, `tb/gls/tb_gls.sv`): each Sky130 cell gets real supply
pins tied to its domain's rail. SkyWater's functional models
(`USE_POWER_PINS`, `FUNCTIONAL`) make a cell output X when its `VPWR` is off,
so the X comes from the library, not from our models. Flops get
`UNIT_DELAY=#1`, a 1 ns delay that avoids zero-delay races between data and
gated clocks (in a zero-delay netlist, a flop's new output and a gated clock
edge can land in the same instant, and the order is arbitrary).

What the test proves: with PD_CMP's rail off, its cells really are X inside
(979 of 979 off cycles), yet no SoC output and no PMU output is ever X, the
host port reads the clamp value, the UART pin stays high while PD_MEM is
off, and after wake the config, scratch, wake count and boot reason are
right. With isolation removed (`--fault`) the X reaches the pins at once.

### 9.13 Where UVM fits

**UVM** (Universal Verification Methodology) is the industry-standard class
library built on exactly these ideas: sequence items (our `mat_job`),
sequencers, drivers, monitors, agents, scoreboards, the factory, and phases.
This environment is "UVM-shaped without UVM": same architecture, fewer
layers, so it runs on Verilator. Porting it to UVM is a listed stretch goal
and a good interview story.

**Check yourself**

1. What's the difference between code and functional coverage?
2. Why does a passing test need a non-zero check count?
3. What makes a formal proof vacuous, and how do covers help?
4. What does BMC prove, and what doesn't it prove?
5. What can GLS find that RTL simulation cannot?

---

## Part 10 - From RTL to silicon

### 10.1 The flow

```
RTL --synthesis--> gate netlist --floorplan--> --placement--> --clock tree-->
    --routing--> --extraction--> --sign-off (STA, power, DRC, LVS)--> GDS
```

**GDS** (GDSII) is the final layout file: polygons on each manufacturing
layer. This project runs the whole flow with **OpenROAD-flow-scripts (ORFS)**
in GitHub Actions.

### 10.2 Standard cells, Liberty and the PDK

- A **PDK** (process design kit) describes a manufacturing process: layers,
  design rules, transistor models. **Sky130** is SkyWater's open 130 nm
  process; **ASAP7** is a predictive 7 nm academic PDK (not manufacturable,
  realistic for study).
- A **standard-cell library** is a set of pre-designed gates (NAND2, DFF,
  ICG, isolation cells...) of fixed height that tile into rows.
  `sky130_fd_sc_hd` is the high-density library; cell names end in the drive
  strength (`_1`, `_2`, `_4`: bigger is stronger and larger).
- A **Liberty file** (`.lib`) gives each cell's function, area, pin
  capacitance, and timing and power as lookup tables indexed by input slew
  and output load. One file per **corner**: e.g.
  `sky130_fd_sc_hd__tt_025C_1v80.lib` is typical process, 25 C, 1.80 V.
- **LEF** files give each cell's physical outline and pin shapes for place
  and route.

### 10.3 Logic synthesis

Synthesis turns RTL into a netlist of library cells:

1. **Elaborate**: resolve parameters, unroll generate loops, build the
   hierarchy (`hierarchy -top soc_top -chparam MAC_N 4`).
2. **Generic synthesis**: optimise into generic gates, detect flops, FSMs,
   memories (`synth`).
3. **Technology mapping**: flops to library flops (`dfflibmap`), logic to
   library gates (`abc -liberty`), choosing cells to meet timing with least
   area.

**Flattening** dissolves the hierarchy into one module for better
optimisation, but loses instance names. That's why the SoC configs keep
`cmp_top`, `mem_top`, `aon_top` as hierarchy (`SYNTH_KEEP_MODULES`): the
per-domain power report needs to know which cell belongs to which domain.
Cells the optimiser must not remove (isolation, level shifters) are marked
`(* keep *)`.

### 10.4 Static timing analysis (STA)

STA checks the setup and hold inequalities of Part 1.2 for every path,
without simulation, using the Liberty delays and the wire parasitics.
Inputs: the netlist, the libraries, and **constraints** in an SDC file
(`flow/sky130/soc.sdc`):

| SDC command | Meaning here |
| --- | --- |
| `create_clock -period 20 [get_ports clk_in]` | 50 MHz |
| `set_clock_groups -asynchronous -group core_clk -group clk_32k` | don't time paths between them (the synchronisers handle it) |
| `set_clock_uncertainty 0.25` | margin for jitter and skew |
| `set_input_delay / set_output_delay` | how much of the cycle the outside world uses |
| `set_false_path -from [get_ports {por_n gpio_wake ...}]` | async pins, synchronised inside |

Results: **slack** = required time - arrival time per path (negative =
violation). **WNS** is the worst slack, **TNS** the sum of all negative
slacks.

### 10.5 Corners, and timing a multi-voltage chip

Transistor speed varies with **P**rocess (fast/slow wafers), **V**oltage and
**T**emperature. A **corner** fixes all three, e.g. `ss_100C_1v60` = slow
transistors, 100 C, 1.60 V. Rules of thumb:

- **Setup** is worst at the slow corner (low voltage, hot for this process).
- **Hold** is worst at the fast corner (high voltage, cold).
- Supply tolerance: a 1.80 V supply is signed off at 1.60 V for setup
  (about 10 % droop).

Each OPP needs its own check: OPP-H setup at `ss_100C_1v60` and 20 ns;
OPP-L setup at `ss_100C_1v40` and 40 ns (half frequency at lower voltage);
hold at `ff_n40C_1v95`. The `pnr` workflow runs all of these
(`flow/scripts/sta_corners.tcl`). A path from PD_CMP at 1.50 V into PD_AON at
1.80 V really has its launch at one voltage and capture at another; a
single-library STA run can only approximate it, which is why margin is kept
(commercial tools use multi-voltage STA with per-domain libraries).

**OCV** (on-chip variation): even within one corner, two paths on the same
die differ slightly; sign-off adds derates for it.

### 10.6 Place and route

| Step | What happens | ORFS stage |
| --- | --- | --- |
| floorplan | die and core size (from `CORE_UTILIZATION`), I/O pins, rows | 2 |
| power grid (PDN) | metal straps and rings for VDD and VSS | 2 |
| placement | cells placed (`PLACE_DENSITY`), then legalised into rows | 3 |
| clock tree synthesis (CTS) | buffer tree so every flop gets the clock at nearly the same time (low **skew**) | 4 |
| routing | global then detailed routing of every wire on the metal layers | 5 |
| finishing | fill, extraction of parasitics (SPEF), final reports, GDS | 6 |

Timing is repaired at every stage (buffer insertion, cell resizing). The
reports in the `pnr` artifacts are named by stage (`6_finish.rpt`, ...).

### 10.7 Power analysis

- **Vectorless**: assume a toggle rate for every net (e.g. 10 %). Quick,
  inaccurate.
- **Vector-based**: read real switching activity from simulation. Here
  `run.py power --activity` dumps a VCD of the firmware running, and ORFS
  reads it (`VCD_FILE`, `POWER_FILE_SCOPE=tb_power/dut`). RTL register names
  match the netlist, so most activity annotates.

The report splits **internal** (short-circuit + internal nodes),
**switching** (net capacitance) and **leakage** power, per instance;
`flow/scripts/summarize_power.py` sums by domain and builds the per-state
leakage (ACTIVE: AON+CMP+MEM, IDLE: AON+MEM, SLEEP: AON). That comparison
against `soc_baseline` (no power gating) is the headline result.

### 10.8 IR drop and multi-domain implementation

Current through the resistance of the power grid lowers the supply the
cells see (**IR drop**), making them slower; heavy simultaneous switching
causes dynamic drops. OpenROAD's PDNSim analyses it. A real multi-domain
layout needs a separate grid and **voltage area** (region) per domain, power
switch cells along the domain, always-on routing for the signals that must
stay alive, and isolation and level-shifter cells placed at the boundary. The
experimental `flow/sky130/soc_multidomain` attempts this with
`domains.tcl` and `pdn.tcl`.

### 10.9 Multi-Vt

Libraries come in threshold-voltage flavours: **LVT** (low Vt: fast, leaky),
**RVT** (regular), **HVT** (high Vt: slow, low leakage). The best mix uses
fast cells only on critical paths and slow, frugal cells everywhere else.
The ASAP7 study in `flow/asap7/mac_accel` runs the accelerator with RVT only,
LVT only, and both, then compares maximum frequency, leakage and how many
cells the optimiser chose to make LVT.

**Check yourself**

1. Why is hold checked at the fast corner?
2. What does `set_clock_groups -asynchronous` tell STA, and why is it safe here?
3. Why must the netlist keep the domain hierarchy for the power report?
4. What is clock skew and which step controls it?
5. Why would you not make every cell LVT?

---

## Part 11 - One wake-up, end to end

Everything above, in the order it happens during the firmware test
(`tb/power`, or `python scripts/run.py sim --test test_fw_e2e`):

1. **Cold boot.** `por_n` rises; `rst_sync` releases the system reset on a
   clock edge. The PMU comes up in ACTIVE_H with every domain on.
   PicoRV32 fetches from address 0: `crt0.S` clears registers and `.bss`,
   then `main()` reads `BOOT_REASON` = cold.
2. **Self-test.** The firmware fills A and B over the bus, writes `CFG`
   and `CTRL`. The accelerator's clock gate opens, skewed operands flow
   through the array for K + 2N - 2 cycles, results latch into C, the gate
   closes. The firmware compares C with its own C loop.
3. **DVFS round trip.** Request ACTIVE_L: the PMU sets `freq_lo`, the clock
   switch breaks then makes onto clk_in/2, the synchronised ack comes back,
   then `vsel_hi` drops and the PMU waits for `vdd_ok`. Back to ACTIVE_H in
   the opposite order: voltage, then frequency.
4. **Prepare and request IDLE.** Set the accelerator config (to be
   retained), write `.noinit` RAM, a magic word in AON scratch, a timer
   period and `WAKE_MASK = timer`. Write `PMU_CTRL = IDLE` and spin.
5. **Power-down.** The PMU raises `cmp_pwr_req` and arms the timer (the arm
   toggle crosses into clk_32k). The fabric raises its fence; with nothing in
   flight and the accelerator idle, `cmp_pwr_ack` returns. Clock off, save
   config to the AON shadow, isolation on (every PD_CMP output now reads 0 on
   the receiving side), reset, switch off. In simulation, everything leaving
   PD_CMP becomes X and is stopped by the isolation cells. State = IDLE.
6. **Asleep.** Only PD_AON and PD_MEM are powered. The 32 kHz counter
   counts.
7. **Wake.** The counter reaches the period and flips `match_tgl`; the
   toggle synchroniser turns it into one `ev_timer` pulse in clk_sys (the
   arm-echo check confirms it belongs to this arming). It is enabled in
   `WAKE_MASK`, so `wake_pend` is set.
8. **Power-up.** Switch on, wait for the ack; clock on; reset released with
   the clock running (so PicoRV32 really resets); `restore` loads the config
   from the shadow; isolation off. State = ACTIVE_H (the OPP before
   sleeping). `BOOT_REASON` = warm, from IDLE, source timer.
9. **Warm boot.** The CPU starts at address 0 again. `main()` sees warm boot
   from IDLE, checks the `.noinit` RAM (PD_MEM stayed on) and the config
   (hardware retention), goes to ACTIVE_L and requests SLEEP with GPIO wake.
10. **SLEEP and back.** Same as before, plus PD_MEM going down after PD_CMP
    and coming up before it. After the GPIO wake the firmware checks the AON
    scratch and config, notes the RAM contents were lost (as they must be),
    reruns the accelerator, prints `DONE PASS`.

If you can narrate this with the code open, you understand the project.

---

## Part 12 - Interview-style questions, with short answers

**Low power**

1. *Order of steps to power down a domain, and why?* Quiesce (no transfer
   cut in half), clock off, save state, isolate (receivers see a clamp, not
   X), reset, switch off. Power-up reverses it: power, clock, reset release,
   restore, isolation off.
2. *Where do isolation cells go?* In the receiving, powered domain, on its
   supply. A cell in the dead domain would be dead.
3. *How do you choose a clamp value?* The inactive level of the signal: 0 for
   valid/request, 1 for an active-low or idle-high signal like UART TX.
4. *Why level-shift low-to-high but not high-to-low?* A weak high from a
   low-voltage domain leaves the receiver's PMOS partly on (leakage, poor
   noise margin); a full-swing high into a lower supply is fine here.
5. *Voltage or frequency first when speeding up?* Voltage, after it settles;
   the reverse when slowing down.
6. *Clock gating vs power gating?* Clock gating removes dynamic power, cheap,
   instant, state kept. Power gating removes leakage too, but loses state,
   needs isolation, retention and a wake latency.
7. *Why does rush current matter?* Switching on a large domain at once
   droops the shared supply and can upset always-on logic; switches are
   turned on in stages with an acknowledge.

**CDC**

8. *Why two flops?* The first may go metastable; the second gives it a full
   period to resolve, making failure probability negligible.
9. *How do you cross a multi-bit value?* Not bit by bit. Use a handshake, a
   gray-coded counter (one bit changes at a time), an async FIFO, or a
   quasi-static value guarded by a synchronised control signal.
10. *How do you cross a pulse into a slower clock?* Toggle a level in the
    source, synchronise it, edge-detect in the destination.

**Verification**

11. *What does formal give you that simulation doesn't?* Proof over all
    input sequences, including timings no test generates.
12. *How do you know your testbench can fail?* Fault injection and mutation
    testing: plant bugs, check every one is caught.
13. *What is vacuity?* A property that passes because its precondition never
    happens. Covers detect it.
14. *Why gate-level power simulation if RTL power simulation passed?*
    Synthesis can remove or restructure isolation, and RTL models are our own
    assumptions; cell power models are the library's.

**Physical design**

15. *Setup vs hold corner?* Setup at slow (low V, high T here), hold at
    fast.
16. *What's in a Liberty file?* Cell function, area, pin capacitance, delay
    and power tables vs slew and load, per corner.
17. *Why multi-Vt?* LVT for speed where needed, HVT/RVT elsewhere for
    leakage.
18. *Why vector-based power?* Default toggle rates can be wildly off;
    activity from a real workload gives the real number.

**This design**

19. *Why is CMP-on, MEM-off illegal?* The CPU would access a dead RAM; the
    sequencer orders MEM before CMP on power-up and after it on power-down,
    and formal proves the state unreachable.
20. *Why a shadow register instead of retention flops?* Sky130 HD has none;
    a shadow in AON works for a few bits but forces save before isolation.
21. *Why does the CPU need its clock during reset?* PicoRV32's reset is
    synchronous.

---

## Part 13 - Glossary

| Term | Meaning |
| --- | --- |
| AON | always-on domain |
| ABC | logic optimisation and verification engine used by Yosys (and the PDR prover) |
| BMC | bounded model checking: formal check up to N cycles |
| CDC | clock-domain crossing |
| corner | one combination of process, voltage, temperature for timing/power |
| CTS | clock tree synthesis |
| DUT | design under test |
| DVFS | dynamic voltage and frequency scaling |
| GDS | final layout file |
| GLS | gate-level simulation |
| ICG | integrated clock gate (latch + AND) |
| IC3 / PDR | unbounded model-checking algorithm (property-directed reachability) |
| isolation cell | clamps a signal from an unpowered domain to a fixed value |
| LEF | physical abstract of cells (outline, pins) |
| level shifter | converts a signal between supply voltages |
| Liberty (.lib) | cell timing/power/function library for one corner |
| MAC | multiply-accumulate |
| metastability | a flop output stuck between 0 and 1 after a setup/hold violation |
| OPP | operating performance point: a legal (voltage, frequency) pair |
| ORFS | OpenROAD-flow-scripts: Makefile flow around OpenROAD and Yosys |
| PDK | process design kit |
| PMU | power management unit |
| power domain | logic on one switchable/scalable supply |
| quiesce | bring a block to a safe idle point before power-down |
| retention | keeping state across power-off |
| SDC | timing-constraint file format |
| slack | required minus actual arrival time (negative = violation) |
| SPEF | extracted wire parasitics |
| STA | static timing analysis |
| SVA | SystemVerilog assertions |
| systolic array | grid of PEs passing operands to neighbours |
| UPF | IEEE 1801 power-intent format |
| UVM | standard SystemVerilog verification class library |
| VCD | value change dump: waveform / activity file |
| Vt | transistor threshold voltage (LVT / RVT / HVT flavours) |
| WNS / TNS | worst / total negative slack |
| X | unknown value in 4-state simulation |

---

## Answers to the "check yourself" questions

**Part 1.** (1) Hold compares data arriving too *early* against the same
clock edge; the period doesn't appear in the inequality. (2) A
recovery/removal violation: flops may leave reset in different cycles or go
metastable. (3) Decoded outputs can glitch when state bits change together,
and a glitch on isolation or a switch enable is a real hardware bug.

**Part 2.** (1) Its domain lost power and reset; reset starts at 0. (2) The
PicoRV32 register file has no reset (it's a RAM-like array), so it holds
garbage after power-up. (3) In an AON scratch register (or anything else in
PD_AON).

**Part 3.** (1) The partial sum C[i][j]. (2) A values reach column j after j
cycles and B values reach row i after i cycles; the skew lines up the pairs
that belong together. (3) A sum of K products of up to 16,384 each needs more
than 16 bits. (4) 8 + 16 + 1 = 25 cycles.

**Part 4.** (1) Clock gating reduces alpha; DVFS reduces V and f. (2) Leakage
flows whenever the supply is on, clock or not. (3) When leakage dominates:
the longer job leaks for longer than the V^2 saving recovers.

**Part 5.** (1) The enable can change while the clock is high, producing a
runt pulse. (2) Idle UART is high; a low would be read as a start bit.
(3) The shadow reads the config through the isolation cell; after isolation
it would read 0. (4) The clock must never outrun the voltage, even for a
cycle. (5) Only PD_CMP drops voltage; a 1.80 V signal into 1.50 V logic is
safe here.

**Part 6.** (1) Bring the domain to a point with no transfer in flight and
the accelerator idle; without it a bus transfer could be cut in half and the
receiver left waiting or corrupted. (2) It is latched in `wake_pend`; the
power-down finishes, then the PMU wakes at once. (3) The chip could never
wake up again.

**Part 7.** (1) Both ends run on gated copies of the same `clk_sys`, so it is
one clock domain. (2) The bits could be sampled at different moments and
arrive as a mix of old and new values. (3) An expiry from the previous
arming was still in the synchroniser when the timer was re-armed, and was
counted as a wake for the new power-down. The fix tags expiries with the arm
generation echoed back from the 32 kHz side and drops mismatches.

**Part 8.** (1) Synthesis (and implementation) tools insert them from UPF.
(2) The cell sits in the parent scope, i.e. outside the switched domain, on a
supply that stays on while the domain is off.

**Part 9.** (1) Code coverage measures exercised code structure, functional
coverage measures exercised scenarios from the plan. (2) A test that checked
nothing proves nothing. (3) A precondition that can never happen (often
because of over-strong assumptions); a cover shows the scenario is reachable.
(4) No failure within N cycles; nothing beyond N. (5) Synthesis mismatches,
removed or broken isolation, and power behaviour from the real cell models.

**Part 10.** (1) Fast cells make data arrive earliest, the worst case for
hold. (2) Don't time paths between those clocks; safe because every crossing
is through a synchroniser. (3) Flattening renames most gates, losing which
domain they belong to. (4) The difference in clock arrival time between
flops; CTS. (5) LVT leaks far more; on non-critical paths that leakage buys
nothing.

---

## Where to go deeper

- *CMOS VLSI Design*, Weste and Harris: power, timing, circuits.
- *Low Power Methodology Manual*, Keating et al. (Synopsys/ARM): the classic
  on power gating, isolation, retention and sequencing.
- *Clock Domain Crossing (CDC) Design & Verification Techniques Using
  SystemVerilog*, Clifford Cummings (SNUG paper, free online).
- *SystemVerilog for Verification*, Chris Spear: classes, randomisation,
  coverage.
- IEEE 1801 (UPF) standard, and vendor low-power user guides.
- H.T. Kung, *Why Systolic Architectures?* (IEEE Computer, 1982).
- The OpenROAD-flow-scripts documentation, for each flow stage.
