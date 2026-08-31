# Extra emulation for pdp11-*-rt11* targets, selected explicitly via
# `-m pdp11rt11rel`: produce a relocatable RT-11 object module (the
# native DEC "Relocatable Object Language" format documented in the
# RT-11 Volume and File Formats Manual -- GSD/TXT/RLD/ENDMOD blocks,
# RADIX-50 names) instead of an a.out-pdp11 object.
#
# Like pdp11rt11sav, OUTPUT_FORMAT is deliberately "a.out-pdp11", not a
# format of its own: linking goes through a.out-pdp11's own specialized,
# proven-correct relocatable-link path (pdp11_aout_link_input_section in
# bfd/pdp11.c, in its `if (relocatable)` branch -- this emulation is
# meant to be used with `-r`), producing exactly the file
# `ld -r -m pdp11rt11` would.  Once that file is fully written to disk,
# emultempl/pdp11rt11rel.em's after_close_output hook reads its symbols,
# relocations and section contents back with ordinary a.out-pdp11 BFD
# calls and repacks them into the RT-11 object format in place.  See the
# comment on gld${EMULATION_NAME}_after_close_output in that file for
# the full story.
SCRIPT_NAME=pdp11rt11
OUTPUT_FORMAT="a.out-pdp11"
TEXT_START_ADDR=512
EXTRA_EM_FILE=pdp11rt11rel
ARCH=pdp11
ENTRY=start
