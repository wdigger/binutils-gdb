/* PDP-11 support for 32-bit ELF.
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

/* A 16-bit machine in a 32-bit container: ELF32 with addresses that
   never exceed 64K, which is what msp430 does too.  Nothing here needs
   a GOT, a PLT or dynamic linking -- this target has one address space,
   one program in it at a time, and an operating system that loads a
   flat image.  What it is for is the things a.out cannot express and
   that a machine with 64K of address space badly wants: named sections,
   so --gc-sections has something to collect, and debug information.

   The relocations are in include/elf/pdp11.h, which also explains why
   their numbers are this port's own.  */

#include "sysdep.h"
#include "bfd.h"
#include "libbfd.h"
#include "elf-bfd.h"
#include "elf/pdp11.h"

static reloc_howto_type pdp11_elf_howto_table[] =
{
  /* No relocation.  */
  HOWTO (R_PDP11_NONE,		/* type */
	 0,			/* rightshift */
	 0,			/* size */
	 0,			/* bitsize */
	 false,			/* pc_relative */
	 0,			/* bitpos */
	 complain_overflow_dont, /* complain_on_overflow */
	 bfd_elf_generic_reloc,	/* special_function */
	 "R_PDP11_NONE",	/* name */
	 false,			/* partial_inplace */
	 0,			/* src_mask */
	 0,			/* dst_mask */
	 false),		/* pcrel_offset */

  /* One word, S + A.  The machine's address space is 16 bits wide, so
     there is no overflow to complain about: a value that does not fit
     is not a relocation error, it is a program that does not fit in the
     machine, and the linker says so elsewhere.  */
  HOWTO (R_PDP11_16,
	 0,
	 2,
	 16,
	 false,
	 0,
	 complain_overflow_dont,
	 bfd_elf_generic_reloc,
	 "R_PDP11_16",
	 false,
	 0,
	 0x0000ffff,
	 false),

  /* One word, S + A - P, with P the address of this very word.  The
     -2 for the PDP-11's "PC has already advanced past the operand"
     rule lives in the addend; see include/elf/pdp11.h.  */
  HOWTO (R_PDP11_PCREL16,
	 0,
	 2,
	 16,
	 true,
	 0,
	 complain_overflow_dont,
	 bfd_elf_generic_reloc,
	 "R_PDP11_PCREL16",
	 false,
	 0,
	 0x0000ffff,
	 true),

  /* One byte, S + A.  */
  HOWTO (R_PDP11_8,
	 0,
	 1,
	 8,
	 false,
	 0,
	 complain_overflow_bitfield,
	 bfd_elf_generic_reloc,
	 "R_PDP11_8",
	 false,
	 0,
	 0x000000ff,
	 false),

  /* Four bytes, S + A, little-endian like every other four-byte datum
     in an ELF file -- see include/elf/pdp11.h on why this is not the
     order the machine stores a C long in.  */
  HOWTO (R_PDP11_32,
	 0,
	 4,
	 32,
	 false,
	 0,
	 complain_overflow_dont,
	 bfd_elf_generic_reloc,
	 "R_PDP11_32",
	 false,
	 0,
	 0xffffffff,
	 false),
};

/* Map BFD reloc types to PDP-11 ELF reloc types.  */

struct pdp11_reloc_map
{
  bfd_reloc_code_real_type bfd_reloc_val;
  unsigned int pdp11_reloc_val;
};

static const struct pdp11_reloc_map pdp11_reloc_map[] =
{
  { BFD_RELOC_NONE,	 R_PDP11_NONE },
  { BFD_RELOC_16,	 R_PDP11_16 },
  { BFD_RELOC_16_PCREL,	 R_PDP11_PCREL16 },
  { BFD_RELOC_8,	 R_PDP11_8 },
  { BFD_RELOC_32,	 R_PDP11_32 },
};

static reloc_howto_type *
pdp11_elf_reloc_type_lookup (bfd *abfd ATTRIBUTE_UNUSED,
			     bfd_reloc_code_real_type code)
{
  unsigned int i;

  for (i = 0; i < sizeof (pdp11_reloc_map) / sizeof (pdp11_reloc_map[0]); i++)
    if (pdp11_reloc_map[i].bfd_reloc_val == code)
      return &pdp11_elf_howto_table[pdp11_reloc_map[i].pdp11_reloc_val];

  return NULL;
}

static reloc_howto_type *
pdp11_elf_reloc_name_lookup (bfd *abfd ATTRIBUTE_UNUSED, const char *r_name)
{
  unsigned int i;

  for (i = 0;
       i < sizeof (pdp11_elf_howto_table) / sizeof (pdp11_elf_howto_table[0]);
       i++)
    if (pdp11_elf_howto_table[i].name != NULL
	&& strcasecmp (pdp11_elf_howto_table[i].name, r_name) == 0)
      return &pdp11_elf_howto_table[i];

  return NULL;
}

/* Set the howto pointer for a PDP-11 ELF reloc.  */

static bool
pdp11_elf_info_to_howto (bfd *abfd,
			 arelent *cache_ptr,
			 Elf_Internal_Rela *dst)
{
  unsigned int r_type = ELF32_R_TYPE (dst->r_info);

  if (r_type >= (unsigned int) R_PDP11_max)
    {
      /* xgettext:c-format */
      _bfd_error_handler (_("%pB: unsupported relocation type %#x"),
			  abfd, r_type);
      bfd_set_error (bfd_error_bad_value);
      return false;
    }

  cache_ptr->howto = &pdp11_elf_howto_table[r_type];
  return true;
}

/* Relocate a PDP-11 ELF section.  */

static int
pdp11_elf_relocate_section (bfd *output_bfd,
			    struct bfd_link_info *info,
			    bfd *input_bfd,
			    asection *input_section,
			    bfd_byte *contents,
			    Elf_Internal_Rela *relocs,
			    Elf_Internal_Sym *local_syms,
			    asection **local_sections)
{
  Elf_Internal_Shdr *symtab_hdr;
  struct elf_link_hash_entry **sym_hashes;
  Elf_Internal_Rela *rel;
  Elf_Internal_Rela *relend;

  symtab_hdr = &elf_tdata (input_bfd)->symtab_hdr;
  sym_hashes = elf_sym_hashes (input_bfd);
  relend = relocs + input_section->reloc_count;

  for (rel = relocs; rel < relend; rel++)
    {
      reloc_howto_type *howto;
      unsigned long r_symndx;
      Elf_Internal_Sym *sym;
      asection *sec;
      struct elf_link_hash_entry *h;
      bfd_vma relocation;
      bfd_reloc_status_type r;
      const char *name;
      unsigned int r_type;

      r_type = ELF32_R_TYPE (rel->r_info);
      r_symndx = ELF32_R_SYM (rel->r_info);

      if (r_type >= (unsigned int) R_PDP11_max)
	{
	  /* xgettext:c-format */
	  _bfd_error_handler (_("%pB: unsupported relocation type %#x"),
			      input_bfd, r_type);
	  bfd_set_error (bfd_error_bad_value);
	  return false;
	}

      howto = pdp11_elf_howto_table + r_type;
      h = NULL;
      sym = NULL;
      sec = NULL;

      if (r_symndx < symtab_hdr->sh_info)
	{
	  sym = local_syms + r_symndx;
	  sec = local_sections[r_symndx];
	  relocation = _bfd_elf_rela_local_sym (output_bfd, sym, &sec, rel);

	  name = bfd_elf_string_from_elf_section (input_bfd,
						  symtab_hdr->sh_link,
						  sym->st_name);
	  name = (name == NULL || *name == '\0') ? bfd_section_name (sec) : name;
	}
      else
	{
	  bool unresolved_reloc, warned, ignored;

	  RELOC_FOR_GLOBAL_SYMBOL (info, input_bfd, input_section, rel,
				   r_symndx, symtab_hdr, sym_hashes,
				   h, sec, relocation,
				   unresolved_reloc, warned, ignored);

	  name = h->root.root.string;
	}

      if (sec != NULL && discarded_section (sec))
	RELOC_AGAINST_DISCARDED_SECTION (info, input_bfd, input_section,
					 rel, 1, relend, howto, 0, contents);

      if (bfd_link_relocatable (info))
	continue;

      r = _bfd_final_link_relocate (howto, input_bfd, input_section, contents,
				    rel->r_offset, relocation, rel->r_addend);

      if (r != bfd_reloc_ok)
	{
	  const char *msg = NULL;

	  switch (r)
	    {
	    case bfd_reloc_overflow:
	      (*info->callbacks->reloc_overflow)
		(info, (h ? &h->root : NULL), name, howto->name,
		 (bfd_vma) 0, input_bfd, input_section, rel->r_offset);
	      break;

	    case bfd_reloc_undefined:
	      (*info->callbacks->undefined_symbol)
		(info, name, input_bfd, input_section, rel->r_offset, true);
	      break;

	    case bfd_reloc_outofrange:
	      msg = _("internal error: out of range error");
	      break;

	    case bfd_reloc_notsupported:
	      msg = _("internal error: unsupported relocation error");
	      break;

	    case bfd_reloc_dangerous:
	      msg = _("internal error: dangerous relocation");
	      break;

	    default:
	      msg = _("internal error: unknown error");
	      break;
	    }

	  if (msg)
	    (*info->callbacks->warning) (info, msg, name, input_bfd,
					 input_section, rel->r_offset);
	}
    }

  return true;
}

#define ELF_ARCH		bfd_arch_pdp11
#define ELF_MACHINE_CODE	EM_PDP11
/* The machine has no paging of any kind, and a program is loaded where
   the linker script says.  */
#define ELF_MAXPAGESIZE		0x1

#define TARGET_LITTLE_SYM	pdp11_elf32_vec
#define TARGET_LITTLE_NAME	"elf32-pdp11"
/* The compiler prefixes an underscore, the same as it did for
   a.out; ld's --wrap and -u have to look for the same names.  */
#define elf_symbol_leading_char		'_'

#define elf_info_to_howto_rel			NULL
#define elf_info_to_howto			pdp11_elf_info_to_howto
#define elf_backend_relocate_section		pdp11_elf_relocate_section

#define elf_backend_can_gc_sections		1
#define elf_backend_rela_normal			1

#define bfd_elf32_bfd_reloc_type_lookup		pdp11_elf_reloc_type_lookup
#define bfd_elf32_bfd_reloc_name_lookup		pdp11_elf_reloc_name_lookup

#include "elf32-target.h"
