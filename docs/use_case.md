# Use case and industry relevance

This SoC is the always-on sensing-and-inference island of a battery-powered
edge device: it sleeps almost all the time, wakes on a sensor event or a timer,
runs a small INT8 network, and sleeps again. Examples of products built this
way: wake-word detection in earbuds and smart speakers, vibration anomaly
detection on factory motors, presence detection in cameras, gesture
recognition in wearables.

## Why power gating matters: sleep power dominates at low duty cycle

P_avg = D x P_active + (1 - D) x P_sleep

Illustration (not a measurement): active 1 % of the time at 10 mW, asleep at
100 uW, gives 0.10 mW + 0.099 mW, about 0.2 mW. Half the energy goes to
sleeping, so cutting sleep leakage roughly doubles battery life. Fill in your
own numbers from `docs/results.md`.

## Why DVFS matters: dynamic energy scales with V squared

E_dyn ~ C x V^2, so running a job at 1.50 V instead of 1.80 V cuts its
switching energy by 1 - (1.50 / 1.80)^2, about 31 %, if the deadline allows
the slower clock. The job takes longer, so leakage takes some of that back;
measuring the trade-off is part of the physical-design work.

## Real chips with the same structure

- Arm Ethos-U55 is a microNPU that pairs with a Cortex-M CPU and is
  configurable from 32 to 256 MACs: the same small CPU + MAC array split as
  PD_CMP.
- Alif Ensemble MCUs keep a low-power Cortex-M55 + Ethos-U55 subsystem always
  available to watch for triggers, which then wakes a high-performance
  subsystem: the same always-on island waking bigger compute.
- NVIDIA's open-source NVDLA inference accelerator (Verilog, C model and test
  benches) was the inspiration for the MAC array; no NVDLA RTL is used.
- On NVIDIA Jetson modules, `nvpmodel` picks a power mode that bounds the DVFS
  tables, a larger version of the OPP-H / OPP-L choice here.

## Each feature mapped to industry practice

| Feature here | Where industry uses it | Interview topic |
| --- | --- | --- |
| power switches, isolation, retention | phones, wearables, MCUs | why each sequencing step is in that order |
| UPF (IEEE 1801) | power-aware simulation, synthesis, place and route | which parts open-source tools honour |
| DVFS with operating points | Jetson power modes, CPU governors | voltage before frequency; energy vs deadline |
| INT8 systolic MAC array | NPUs (Ethos-U, NVDLA) | data reuse, utilisation, clock gating the array |
| class-based SV, SVA, coverage | standard verification methodology (UVM builds on it) | coverage closure, assertion-based power checks |
| formal proofs on the PMU | control and low-power verification | proving illegal states unreachable |
| multi-corner STA, IR drop, multi-Vt | physical design sign-off | a corner per OPP; leakage vs speed |
| power-down gate-level simulation | netlist-level power verification | catching isolation lost in synthesis |

## Sources

- [Arm: Cortex-M55 and Ethos-U55](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/cortex-m55-and-ethos-u55-processors-extending-the-performance-of-arm-ml-portfolio-for-endpoint-devices)
- [Embedded Computing Design: Alif always-on Ethos-U55 subsystem](https://embeddedcomputing.com/technology/ai-machine-learning/ai-logic-devices-worload-acceleration/alif-semiconductor-achieves-increased-power-performance-for-ai-ml-on-arm-ethos-u55-micronpu-and-cortex-m55-cpu-core)
- [NVDLA](https://nvdla.org/)
- [NVIDIA forum: nvpmodel and the Jetson DVFS tables](https://forums.developer.nvidia.com/t/how-to-adjust-the-cpu-and-gpu-frequency-dynamically-on-jetson-tx2-with-c-c/69064)
- [IEEE 1801-2024 (UPF)](https://standards.ieee.org/ieee/1801/7466/)
