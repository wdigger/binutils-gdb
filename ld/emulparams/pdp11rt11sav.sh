# Default emulation for pdp11-*-rt11* targets: produce an RT-11 SAV
# executable from a single `ld` invocation.
#
# OUTPUT_FORMAT is deliberately the ordinary object format, the same as
# plain pdp11rt11, and not "sav-pdp11": linking goes through the real
# backend's own relocation-resolution path, producing exactly the file
# `ld -m pdp11rt11` would.  Once that file is fully written to disk,
# emultempl/pdp11rt11sav.em's after_close_output hook converts it to the
# RT-11 SAV format in place -- a relocation-free repack (the file's
# section contents are already final, absolute bytes at that point), the
# same conversion `objcopy -O sav-pdp11` already does correctly.  See the
# comment on gld${EMULATION_NAME}_after_close_output in that file for the
# full story, including why sav-pdp11 was not used as OUTPUT_FORMAT
# directly here.
SCRIPT_NAME=pdp11rt11
TEMPLATE_NAME=elf
OUTPUT_FORMAT="elf32-pdp11"
TEXT_START_ADDR=512
EXTRA_EM_FILE=pdp11rt11sav
ARCH=pdp11
ENTRY=start
EMBEDDED=yes
