# Emulation for pdp11-*-rt11*: an ELF object, laid out as the single
# flat image RT-11 loads, by ld/scripttempl/pdp11rt11.sc.
#
# TEMPLATE_NAME is elf, not the generic template the a.out emulations
# use: the ELF-specific work an emulation has to do -- recording program
# headers among it -- lives in emultempl/elf.em, and without it the
# linker produces an ELF file with no PT_LOAD at all and warns that every
# allocated section is "not in segment".
SCRIPT_NAME=pdp11rt11
TEMPLATE_NAME=elf
OUTPUT_FORMAT="elf32-pdp11"
TEXT_START_ADDR=512
ARCH=pdp11
ENTRY=start
EMBEDDED=yes
