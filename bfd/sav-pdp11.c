/* BFD back-end for RT-11 SAV executables (PDP-11).
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

/* This is a write-only BFD backend that produces RT-11 ".sav" executable
   images directly from ld/objcopy, for the pdp11-aout target, in place of
   the external pdp11-aout -> .lda (bin2load) -> .sav (lda2sav) pipeline.

   A SAV file is a flat memory image of the loaded program: file offset 0
   is PDP-11 address 0.  The first 512-byte block (addresses 0 through
   0777 octal) is a fixed-format header; real program code/data occupies
   the rest of the image, and by long-standing convention for this
   toolchain always starts at address 01000 octal (matching the
   pdp11-aout.ld linker script's `phys = 00001000;`).

   Within that header block (all fields native PDP-11 byte order, i.e.
   little-endian words):
     - byte offset 0360 (octal): a per-512-byte-block "used" bitmap
       covering the whole file, one bit per block, MSB first within each
       byte -- used by RT-11 for core allocation.
     - word index 020 (octal), byte offset 040: the program's start
       (entry) address.
     - word index 021 (octal), byte offset 042: initial SP -- the top
       of memory available to a user job (SAV_STACK_ADDRESS below, or
       the program's own top if that's higher -- see
       sav_pdp11_write_object_contents), *not* the entry address.
       RT-11 copies this word into low memory at address 042 before
       transferring control, so a program's startup code can read it
       back via `mov @$042,sp` instead of hardcoding a stack address of
       its own.
     - word index 024 (octal), byte offset 050: the program's "high
       limit" -- total image size in bytes.
   Everything else in the header is zero.

   These field offsets were reverse-engineered from two known-working
   reference tools already used by this toolchain,
   pdp11-toolchain/hello-gcc/lda2sav.c and savbmap.c -- both of which
   (incorrectly) set the initial-SP word to the entry address rather
   than the top of user memory; this backend does not repeat that
   mistake (see SAV_STACK_ADDRESS).

   Modeled on bfd/binary.c and bfd/srec.c: like binary.c, the "address
   space" is what defines file layout; like srec.c, we need to write a
   trailer (here, a header) that depends on information -- the highest
   address used, the true entry point -- only known once every section
   has been written, so section data is buffered in memory and the whole
   image is written out in bfd_close(), from the _bfd_write_contents
   jump-table slot.  */

#include "sysdep.h"
#include "bfd.h"
#include "libbfd.h"

/* A PDP-11 address space is 64K.  */
#define SAV_IMAGE_SIZE		65536
#define SAV_HEADER_SIZE		  512

/* The header block reserves addresses 0 through 0777 (octal); real
   program content starts at 01000 (decimal 512).  */
#define SAV_LOAD_ADDRESS	  512

/* Default top of memory available to a user job under this project's
   RT-11 configuration: the resident monitor (RT11SJ.SYS, currently
   40448 bytes on disk, taken here as an upper bound on its resident
   footprint) sits immediately below the fixed Unibus I/O page at
   0160000, so 0160000 - 40448 = 041000 (16896 decimal) is the highest
   address a *small* program can assume is safe without asking.  RT-11
   itself copies this same value from word SAV_SP_WORD of the file we
   write here into low memory at address 042 (octal) before
   transferring control, so a program's startup code can pick it up via
   `mov @$042,sp` instead of hardcoding it -- but only as a
   *provisional* value: crt0 immediately asks the monitor for the real
   answer via `.SETTOP` and replaces SP with that.  This constant is
   necessarily specific to the RT11SJ.SYS build this project ships
   (resident driver selection changes the monitor's footprint) --
   revisit if that changes.

   Provisional does not mean irrelevant, though: `.SETTOP` is itself an
   EMT, and an EMT's trap entry pushes the return PC/PS onto whatever
   SP already holds *before* crt0 gets to replace it -- so this value
   must never be lower than the program's own top of used memory.  A
   program larger than SAV_STACK_ADDRESS (e.g. once printf/rand pull in
   enough of libc/libgcc) would otherwise get a provisional SP that
   points *inside* its own already-loaded code, and that first EMT's
   automatic push corrupts it before the program executes a single
   instruction of its own.  sav_pdp11_write_object_contents() guards
   against this by raising the written SP word to the program's real
   top when that exceeds this default.  */
#define SAV_STACK_ADDRESS	16896

/* Byte offset of the block-usage bitmap within the header.  */
#define SAV_BITMAP_OFFSET	 0360

/* Word indices (not byte offsets) of the header's address/size fields.  */
#define SAV_START_WORD		  020
#define SAV_SP_WORD		  021
#define SAV_HIGHLIMIT_WORD	  024

/* Create a SAV object for writing: allocate the flat 64K memory image
   that set_section_contents fills in and write_object_contents dumps to
   the file.  */

/* pdp11-aout has an odd quirk that matters here: a linked executable's
   *entry point* is stored as an absolute address (matching the
   toolchain-wide convention that programs load and run starting at
   01000), but its *section* VMA/LMA are always reported relative to 0,
   regardless of where the linker script actually placed them -- classic
   a.out has no field to record a separate base load address, so the
   format simply doesn't preserve it in section addresses.  That means
   the address a section reports here can be either 0-based (reading an
   already-linked a.out-pdp11 file, e.g. via objcopy) or already
   01000-based (linking straight to sav-pdp11 with `ld --oformat`, where
   the linker script's absolute addresses are still in effect).  Rather
   than assume either convention, we find the *lowest* LMA among all
   loaded sections on the first call and treat that as "the start of the
   program", mapping it to image offset SAV_LOAD_ADDRESS -- this lines up
   correctly either way.  */

struct sav_pdp11_data
{
  bfd_byte *image;
  bfd_vma base;
  bool have_base;
};

static bool
sav_pdp11_mkobject (bfd *abfd)
{
  struct sav_pdp11_data *tdata;

  tdata = (struct sav_pdp11_data *) bfd_zalloc (abfd, sizeof (*tdata));
  if (tdata == NULL)
    return false;
  tdata->image = (bfd_byte *) bfd_zalloc (abfd, SAV_IMAGE_SIZE);
  if (tdata->image == NULL)
    return false;
  abfd->tdata.any = (void *) tdata;
  return true;
}

#define sav_pdp11_close_and_cleanup	_bfd_generic_close_and_cleanup
#define sav_pdp11_bfd_free_cached_info	_bfd_generic_bfd_free_cached_info
#define sav_pdp11_new_section_hook	_bfd_generic_new_section_hook
#define sav_pdp11_get_section_contents	_bfd_generic_get_section_contents

/* Find the lowest LMA among all loaded sections; see the big comment
   above struct sav_pdp11_data.  */

static bfd_vma
sav_pdp11_find_base (bfd *abfd)
{
  asection *s;
  bfd_vma base = 0;
  bool found = false;

  for (s = abfd->sections; s != NULL; s = s->next)
    {
      if ((s->flags & (SEC_HAS_CONTENTS | SEC_LOAD | SEC_ALLOC
			| SEC_NEVER_LOAD))
	  != (SEC_HAS_CONTENTS | SEC_LOAD | SEC_ALLOC)
	  || s->size == 0)
	continue;

      if (!found || s->lma < base)
	{
	  base = s->lma;
	  found = true;
	}
    }

  return base;
}

/* Copy section data straight into the flat memory image, mapping the
   lowest section address found across the whole output to image offset
   SAV_LOAD_ADDRESS (see sav_pdp11_find_base).  Sections beyond the 64K
   PDP-11 address space cannot be represented and are reported as link
   errors rather than silently truncated.  */

static bool
sav_pdp11_set_section_contents (bfd *abfd,
				 asection *section,
				 const void * location,
				 file_ptr offset,
				 bfd_size_type count)
{
  struct sav_pdp11_data *tdata = (struct sav_pdp11_data *) abfd->tdata.any;
  bfd_vma addr;

  if (count == 0)
    return true;

  if ((section->flags & (SEC_LOAD | SEC_ALLOC | SEC_NEVER_LOAD))
      != (SEC_LOAD | SEC_ALLOC))
    return true;

  if (!tdata->have_base)
    {
      tdata->base = sav_pdp11_find_base (abfd);
      tdata->have_base = true;
    }

  if (section->lma < tdata->base)
    {
      _bfd_error_handler
	/* xgettext:c-format */
	(_("%pB: section `%pA' starts below the lowest section address "
	   "seen for this output"),
	 abfd, section);
      bfd_set_error (bfd_error_bad_value);
      return false;
    }

  addr = SAV_LOAD_ADDRESS + (section->lma - tdata->base) + offset;
  if (addr + count > SAV_IMAGE_SIZE)
    {
      _bfd_error_handler
	/* xgettext:c-format */
	(_("%pB: section `%pA' does not fit in the 64K PDP-11 address "
	   "space"),
	 abfd, section);
      bfd_set_error (bfd_error_bad_value);
      return false;
    }

  memcpy (tdata->image + addr, location, (size_t) count);
  return true;
}

#define sav_pdp11_set_arch_mach  _bfd_generic_set_arch_mach

/* Finalize and write out the file: locate the highest address used by
   any loaded section, build the 512-byte header in place at the front
   of the image (block-usage bitmap plus the three address/size words),
   then write the whole image out in one go.  This runs once from
   bfd_close(), after all section data has been deposited by
   sav_pdp11_set_section_contents.  */

static bool
sav_pdp11_write_object_contents (bfd *abfd)
{
  struct sav_pdp11_data *tdata = (struct sav_pdp11_data *) abfd->tdata.any;
  bfd_byte *image = tdata->image;
  bfd_vma highest = SAV_LOAD_ADDRESS;
  bfd_vma highest_alloc = SAV_LOAD_ADDRESS;
  asection *s;
  bfd_size_type image_size;
  unsigned int blocks, full_bytes, rem_bits;
  bfd_vma start, sp;

  if (!tdata->have_base)
    {
      tdata->base = sav_pdp11_find_base (abfd);
      tdata->have_base = true;
    }

  for (s = abfd->sections; s != NULL; s = s->next)
    {
      bfd_vma end;

      if ((s->flags & (SEC_ALLOC | SEC_NEVER_LOAD)) != SEC_ALLOC
	  || s->size == 0)
	continue;

      end = SAV_LOAD_ADDRESS + (s->lma - tdata->base) + s->size;

      /* .bss and similar zero-initialized sections carry no file
	 content, so they never move `highest` (the file image's own
	 length) -- but they are still real, live memory that crt0's
	 stack must not land on top of, so they always move
	 `highest_alloc` below.  */
      if ((s->flags & (SEC_HAS_CONTENTS | SEC_LOAD)) == (SEC_HAS_CONTENTS | SEC_LOAD)
	  && end > highest)
	highest = end;
      if (end > highest_alloc)
	highest_alloc = end;
    }

  /* The file itself is written at its exact byte length -- it is *not*
     padded out to a block boundary (matching the reference lda2sav.c
     tool this backend replaces).  Only the block-usage bitmap below
     rounds up, since it has to describe whole blocks.  */
  image_size = highest;
  if (image_size > SAV_IMAGE_SIZE)
    image_size = SAV_IMAGE_SIZE;

  /* Block-usage bitmap: mark every 512-byte block from 0 up to and
     including the last one actually used.  */
  blocks = (unsigned int) ((image_size + SAV_HEADER_SIZE - 1)
			    / SAV_HEADER_SIZE);
  full_bytes = blocks / 8;
  rem_bits = blocks % 8;
  memset (image + SAV_BITMAP_OFFSET, 0xff, full_bytes);
  if (rem_bits != 0)
    image[SAV_BITMAP_OFFSET + full_bytes]
      = (bfd_byte) (0xff ^ ((1 << (8 - rem_bits)) - 1));

  start = bfd_get_start_address (abfd);
  if (start == 0)
    start = SAV_LOAD_ADDRESS;

  /* SAV_STACK_ADDRESS is only a *default* -- it assumes a program small
     enough to fit entirely below the resident monitor's footprint.  A
     program whose own code/data (including .bss) extends past that
     point needs a provisional SP at least as high as its own top,
     otherwise crt0's very first EMT (`.SETTOP`, before `mov r0,sp`
     replaces this value with the monitor's real answer) pushes PC/PS
     onto a stack that starts inside the program's own already-loaded
     text, silently corrupting it.  (Found via a real crash: a program
     linked to ~20KB had this word set to the hardcoded 16896, and its
     first EMT clobbered code just below that boundary.)  */
  sp = SAV_STACK_ADDRESS;
  if (highest_alloc > sp)
    sp = highest_alloc;

  bfd_putl16 (start, image + SAV_START_WORD * 2);
  bfd_putl16 (sp, image + SAV_SP_WORD * 2);
  bfd_putl16 ((bfd_vma) image_size, image + SAV_HIGHLIMIT_WORD * 2);

  if (bfd_seek (abfd, (file_ptr) 0, SEEK_SET) != 0)
    return false;

  return bfd_write (image, image_size, abfd) == image_size;
}

#define sav_pdp11_sizeof_headers  _bfd_nolink_sizeof_headers

#define sav_pdp11_bfd_get_relocated_section_contents \
  bfd_generic_get_relocated_section_contents
#define sav_pdp11_bfd_relax_section		bfd_generic_relax_section
#define sav_pdp11_bfd_gc_sections		bfd_generic_gc_sections
#define sav_pdp11_bfd_lookup_section_flags \
  bfd_generic_lookup_section_flags
#define sav_pdp11_bfd_merge_sections		bfd_generic_merge_sections
#define sav_pdp11_bfd_is_group_section		bfd_generic_is_group_section
#define sav_pdp11_bfd_group_name		bfd_generic_group_name
#define sav_pdp11_bfd_discard_group		bfd_generic_discard_group
#define sav_pdp11_section_already_linked \
  _bfd_generic_section_already_linked
#define sav_pdp11_bfd_define_common_symbol \
  bfd_generic_define_common_symbol
#define sav_pdp11_bfd_link_hide_symbol	_bfd_generic_link_hide_symbol
#define sav_pdp11_bfd_define_start_stop	bfd_generic_define_start_stop
#define sav_pdp11_bfd_link_hash_table_create \
  _bfd_generic_link_hash_table_create
#define sav_pdp11_bfd_link_just_syms		_bfd_generic_link_just_syms
#define sav_pdp11_bfd_copy_link_hash_symbol_type \
  _bfd_generic_copy_link_hash_symbol_type
#define sav_pdp11_bfd_link_add_symbols	_bfd_generic_link_add_symbols
#define sav_pdp11_bfd_final_link		_bfd_generic_final_link
#define sav_pdp11_bfd_link_split_section \
  _bfd_generic_link_split_section
#define sav_pdp11_bfd_link_check_relocs	_bfd_generic_link_check_relocs

const bfd_target sav_pdp11_vec =
{
  "sav-pdp11",			/* Name.  */
  bfd_target_unknown_flavour,
  BFD_ENDIAN_LITTLE,		/* Target byte order.  */
  BFD_ENDIAN_LITTLE,		/* Target headers byte order.  */
  EXEC_P,			/* Object flags.  */
  (SEC_CODE | SEC_DATA | SEC_ROM | SEC_HAS_CONTENTS
   | SEC_ALLOC | SEC_LOAD),	/* Section flags.  */
  0,				/* Leading underscore.  */
  ' ',				/* AR_pad_char.  */
  16,				/* AR_max_namelen.  */
  0,				/* Match priority.  */
  TARGET_KEEP_UNUSED_SECTION_SYMBOLS, /* Keep unused section symbols.  */
  bfd_getl64, bfd_getl_signed_64, bfd_putl64,
  bfd_getl32, bfd_getl_signed_32, bfd_putl32,
  bfd_getl16, bfd_getl_signed_16, bfd_putl16,	/* Data.  */
  bfd_getl64, bfd_getl_signed_64, bfd_putl64,
  bfd_getl32, bfd_getl_signed_32, bfd_putl32,
  bfd_getl16, bfd_getl_signed_16, bfd_putl16,	/* Hdrs.  */

  {				/* bfd_check_format.  */
    _bfd_dummy_target,
    _bfd_dummy_target,		/* No read support.  */
    _bfd_dummy_target,
    _bfd_dummy_target,
  },
  {				/* bfd_set_format.  */
    _bfd_bool_bfd_false_error,
    sav_pdp11_mkobject,
    _bfd_bool_bfd_false_error,
    _bfd_bool_bfd_false_error,
  },
  {				/* bfd_write_contents.  */
    _bfd_bool_bfd_false_error,
    sav_pdp11_write_object_contents,
    _bfd_bool_bfd_false_error,
    _bfd_bool_bfd_false_error,
  },

  BFD_JUMP_TABLE_GENERIC (sav_pdp11),
  BFD_JUMP_TABLE_COPY (_bfd_generic),
  BFD_JUMP_TABLE_CORE (_bfd_nocore),
  BFD_JUMP_TABLE_ARCHIVE (_bfd_noarchive),
  BFD_JUMP_TABLE_SYMBOLS (_bfd_nosymbols),
  BFD_JUMP_TABLE_RELOCS (_bfd_norelocs),
  BFD_JUMP_TABLE_WRITE (sav_pdp11),
  BFD_JUMP_TABLE_LINK (sav_pdp11),
  BFD_JUMP_TABLE_DYNAMIC (_bfd_nodynamic),

  NULL,

  NULL
};
