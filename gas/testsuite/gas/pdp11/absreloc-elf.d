#name: pdp11 absreloc
#source: absreloc.s
#objdump: -drw

.*:     file format .*


Disassembly of section .text:

00000000 <start>:
   0:	0bf7 fffc      	tst	\$0 <start>
   4:	0bdf 0000      	tst	\*\$0	6: R_PDP11_16	.text
   8:	0bf7 0000      	tst	\$c <start\+0xc>	a: R_PDP11_PCREL16	\*ABS\*\+0x12
   c:	0bdf 0014      	tst	\*\$24
  10:	0bf7 0000      	tst	\$14 <start\+0x14>	12: R_PDP11_PCREL16	\*ABS\*\+0x12
  14:	0bdf 0014      	tst	\*\$24
