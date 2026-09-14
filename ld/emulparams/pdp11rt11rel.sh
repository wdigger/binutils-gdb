# Extra emulation for pdp11-*-rt11* targets, selected explicitly via
# `-m pdp11rt11rel`: produce a relocatable RT-11 object module (the
# native DEC "Relocatable Object Language" format documented in the
# RT-11 Volume and File Formats Manual -- GSD/TXT/RLD/ENDMOD blocks,
# RADIX-50 names) instead of an ordinary object.
#
# Like pdp11rt11sav, OUTPUT_FORMAT is deliberately the ordinary object
# format and not one of its own: linking goes through that backend's own
# relocatable-link path (this emulation is meant to be used with `-r`),
# producing exactly the file `ld -r -m pdp11rt11` would.  Once that file
# is fully written to disk,
# emultempl/pdp11rt11rel.em's after_close_output hook reads its symbols,
# relocations and section contents back with ordinary BFD calls and
# repacks them into the RT-11 object format in place.  See the
# comment on gld${EMULATION_NAME}_after_close_output in that file for
# the full story.
SCRIPT_NAME=pdp11rt11
TEMPLATE_NAME=elf
OUTPUT_FORMAT="elf32-pdp11"
TEXT_START_ADDR=512
EXTRA_EM_FILE=pdp11rt11rel
ARCH=pdp11
ENTRY=start
EMBEDDED=yes
