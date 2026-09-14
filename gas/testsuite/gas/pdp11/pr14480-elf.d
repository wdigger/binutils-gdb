#name: PR 14480 - correct assembly of 'jsr pc, @(r0)'
#source: pr14480.s
#objdump: -drw

.*: +file format .*

Disassembly of section .text:

0+00 <start>:
[ 	]+0:[ 	]+15c0 0000[ 	]+mov[ 	]+\$0, r0	2: R_PDP11_16	\.text\+0x14
[ 	]+4:[ 	]+09c8[ 	]+jsr[ 	]+pc, \(r0\)
[ 	]+6:[ 	]+09f8 0000[ 	]+jsr[ 	]+pc, \*0\(r0\)
[ 	]+a:[ 	]+09f8 0000[ 	]+jsr[ 	]+pc, \*0\(r0\)
[ 	]+e:[ 	]+09f8 0002[ 	]+jsr[ 	]+pc, \*2\(r0\)
#pass
