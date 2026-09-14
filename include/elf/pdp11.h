/* PDP-11 ELF support for BFD.
   Copyright (C) 2026 Free Software Foundation, Inc.

   This file is part of BFD, the Binary File Descriptor library.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street - Fifth Floor, Boston,
   MA 02110-1301, USA.  */

#ifndef _ELF_PDP11_H
#define _ELF_PDP11_H

#include "elf/reloc-macros.h"

/* There is no published psABI for the PDP-11: EM_PDP11 is reserved in
   the ELF spec and nothing else was ever defined, so these numbers are
   this port's own.  Nothing outside this toolchain reads them, which
   also means new ones can simply be appended.

   RELA throughout, and the relocations below are the whole set the
   machine needs -- the a.out backend gets by with three.  Two notes on
   what is deliberately absent:

   - Branch displacements (the 8-bit one in bne and friends, the 6-bit
     backwards one in sob) have no relocation here.  The assembler
     resolves them itself and a branch to a symbol it cannot resolve is
     already an error rather than a relocation, so nothing can reach the
     linker.  If that ever changes they get appended.

   - There is no separate "PC-relative, biased by the word size".  A
     PDP-11 PC-relative operand is reached from the address *after* the
     word holding the displacement, so the addend carries the -2, the
     same way R_386_PC32 carries -4.  R_PDP11_PCREL16 itself is plain
     S + A - P, with P the address of the relocated word.  */

START_RELOC_NUMBERS (elf_pdp11_reloc_type)
  RELOC_NUMBER (R_PDP11_NONE,	  0)
  /* One word, S + A.  */
  RELOC_NUMBER (R_PDP11_16,	  1)
  /* One word, S + A - P; see above for where the -2 lives.  */
  RELOC_NUMBER (R_PDP11_PCREL16,  2)
  /* One byte, S + A.  */
  RELOC_NUMBER (R_PDP11_8,	  3)
  /* Four bytes, S + A, little-endian.

     Worth a word on why, because the machine itself stores a 32-bit
     quantity as two words with the high one first -- 0x12345678 is the
     bytes 34 12 78 56.  That is a property of how a C long is laid out,
     not of the file: an ELF header says the file is little-endian, and
     the linker, readelf and every DWARF consumer read a four-byte field
     accordingly.  Since the compiler emits a long as two .word
     directives in the machine's own order and never as a .long, nothing
     is lost by letting the file format have its way here -- and the
     four-byte fields of the debug information become readable, which
     they could not otherwise be.  */
  RELOC_NUMBER (R_PDP11_32,	  4)
END_RELOC_NUMBERS (R_PDP11_max)

#endif /* _ELF_PDP11_H */
