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

# Folding .rodata/.data into the same output section as .text (below)
# is only correct for a final, address-assigning link: RELOCATING is
# unset for a `-r' link, which must instead keep .data as its own
# separate output section, exactly like the plain (non-flat-image)
# pdp11.sc does -- a `-r' object is meant to be fed into a later link
# (or converted straight to RT-11's own REL format by pdp11rt11rel),
# and either one needs to still be able to tell .text and .data apart.
# Folding them here too, unconditionally, used to make every `-r' link
# of more than one input object silently lose its .data contents: they
# ended up physically inside what the header called .text, while
# obj_datasec()'s own size came out 0.
if test -z "${RELOCATING}"; then
  DATA_IN_TEXT=
  SEPARATE_DATA_SECTION="
  .data :
  {
    *(.rodata)
    *(.rodata.*)
    *(.data)
  }"
else
  DATA_IN_TEXT="
    *(.rodata)
    *(.rodata.*)
    *(.data)"
  SEPARATE_DATA_SECTION=
fi

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
    *(.text)${DATA_IN_TEXT}
    ${CONSTRUCTING+CONSTRUCTORS}
    ${RELOCATING+. = ALIGN(8);}
    ${RELOCATING+_etext = .;}
    ${RELOCATING+__etext = .;}
  }
${SEPARATE_DATA_SECTION}
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
