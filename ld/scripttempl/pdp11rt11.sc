# Copyright (C) 2026 Free Software Foundation, Inc.
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.
#
# Default linker script for the pdp11rt11 emulation: a single flat
# image starting at ${TEXT_START_ADDR} (01000 octal by default), with
# .text/.rodata/.data merged into one output section rather than
# separate page-aligned segments -- this leaves the whole 64K PDP-11
# address space usable and matches the memory layout RT-11 SAV
# executables need (address 0 through 0777 octal is reserved for the
# SAV file header; real code and data start right after it).  This is
# the built-in equivalent of the pdp11-aout.ld script used by the UKNC
# toolchain, so a plain `ld -o out foo.o` no longer needs `-T`.

test -z "${BIG_OUTPUT_FORMAT}" && BIG_OUTPUT_FORMAT=${OUTPUT_FORMAT}
test -z "${LITTLE_OUTPUT_FORMAT}" && LITTLE_OUTPUT_FORMAT=${OUTPUT_FORMAT}

cat <<EOF
/* Copyright (C) 2026 Free Software Foundation, Inc.

   Copying and distribution of this script, with or without modification,
   are permitted in any medium without royalty provided the copyright
   notice and this notice are preserved.  */

OUTPUT_FORMAT("${OUTPUT_FORMAT}", "${BIG_OUTPUT_FORMAT}",
	      "${LITTLE_OUTPUT_FORMAT}")
OUTPUT_ARCH(${ARCH})
${RELOCATING+ENTRY(${ENTRY})}

${RELOCATING+${LIB_SEARCH_DIRS}}
${RELOCATING+${EXECUTABLE_SYMBOLS}}
SECTIONS
{
  ${RELOCATING+. = ${TEXT_START_ADDR};}
  .text :
  {
    ${RELOCATING+PROVIDE (code = .);}
    *(.text)
    *(.rodata)
    *(.rodata.*)
    *(.data)
    ${CONSTRUCTING+CONSTRUCTORS}
    ${RELOCATING+. = ALIGN(8);}
    ${RELOCATING+_etext = .;}
    ${RELOCATING+__etext = .;}
  }
  .bss :
  {
    ${RELOCATING+__bss_start = .;}
    *(.bss)
    *(COMMON)
    ${RELOCATING+. = ALIGN(2);}
    ${RELOCATING+_end = .;}
    ${RELOCATING+__end = .;}
  }
  ${RELOCATING+PROVIDE (end = .);}
}
EOF
