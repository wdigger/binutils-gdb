#name: PR 26001 - distinguish register names from symbols
#source: pr26001.s
#objdump: -drw

.*: +file format .*

Disassembly of section .text:

0+00 <start>:
[ 	]+0:[ 	]+09f7 0000[ 	]+jsr[ 	]+pc, 4 <start\+0x4>	2: R_PDP11_PCREL16	sprintf-0x2
[ 	]+4:[ 	]+1037 0000[ 	]+mov[ 	]+r0, \$8 <start\+0x8>	6: R_PDP11_PCREL16	\.data-0x2
[ 	]+8:[ 	]+1dc1 0000[ 	]+mov[ 	]+\$c <r00f\+0xa>, r1	a: R_PDP11_PCREL16	\.data
#pass
