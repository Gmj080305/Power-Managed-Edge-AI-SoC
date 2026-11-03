# crt0.S - reset entry. Runs on every boot: cold (power-on) and warm (wake
# from IDLE/SLEEP), because PD_CMP is powered off and the CPU restarts.
# The register file is NOT reset in hardware, so clear it here.
    .section .text.start
    .global _start
_start:
    li x1, 0
    li x3, 0
    li x4, 0
    li x5, 0
    li x6, 0
    li x7, 0
    li x8, 0
    li x9, 0
    li x10, 0
    li x11, 0
    li x12, 0
    li x13, 0
    li x14, 0
    li x15, 0
    li x16, 0
    li x17, 0
    li x18, 0
    li x19, 0
    li x20, 0
    li x21, 0
    li x22, 0
    li x23, 0
    li x24, 0
    li x25, 0
    li x26, 0
    li x27, 0
    li x28, 0
    li x29, 0
    li x30, 0
    li x31, 0
    la sp, _stack_top
    # clear .bss (the .noinit section is left alone on purpose)
    la a0, _bss_start
    la a1, _bss_end
1:  bgeu a0, a1, 2f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 1b
2:  call main
3:  j 3b
