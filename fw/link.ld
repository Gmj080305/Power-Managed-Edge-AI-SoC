/* link.ld - 4 KB boot ROM at 0x0, 512 B scratch RAM at 0x10000000 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
  RAM (rw)  : ORIGIN = 0x10000000, LENGTH = 512
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
  } > ROM

  /* Survives a CMP-only power-down (IDLE), lost in SLEEP. Never cleared. */
  .noinit (NOLOAD) : {
    *(.noinit .noinit.*)
    . = ALIGN(4);
  } > RAM

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > RAM

  /* No initialised data: there is no ROM->RAM copy loop in crt0. */
  .data : { *(.data .data.* .sdata .sdata.*) } > RAM
  ASSERT(SIZEOF(.data) == 0, "initialised .data is not supported; use const or .noinit")

  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(_bss_end + 256 <= _stack_top, "less than 256 B left for the stack")
}
