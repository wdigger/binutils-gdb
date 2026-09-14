# This shell script emits a C file. -*- C -*-
#   Copyright (C) 2026 Free Software Foundation, Inc.
#
# This file is part of the GNU Binutils.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street - Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# An EXTRA_EM_FILE on top of emultempl/elf.em: everything an ELF
# emulation does, plus one hook, after_close_output, and the REL
# writer it calls.  (It used to carry a copy of emultempl/pdp11.em's
# option handling and script selection as well, because the emulation
# was built on the generic template rather than the ELF one; elf.em
# does all of that.)

fragment <<EOF

#include "libiberty.h"
#include <errno.h>

/* ==================================================================
   RT-11 native relocatable object format ("REL": GSD/TXT/RLD/ENDMOD
   blocks, RADIX-50 names) writer.

   Field layouts and semantics below are all taken directly from the
   "RT-11 Volume and File Formats Manual" (DEC, AA-PD6PA-TC), chapter 2
   -- not guessed at.  Nothing in this project's own toolchain or test
   setup ever reads this format back: it exists purely so \`ld -r -m
   ${EMULATION_NAME}\` can emit a module in RT-11's own native
   relocatable object representation, mirroring how pdp11rt11sav emits
   RT-11's native *executable* representation (SAV).  Both work the
   same way: link for real through the object format's own proven
   relocation code first (final link for SAV, \`-r\` link for this),
   then repack the result -- here, by reading it back with ordinary BFD
   calls (bfd_canonicalize_symtab/reloc, bfd_get_section_contents) and
   re-emitting it block by block, rather than trying to make a
   from-scratch BFD target understand this format on both ends.

   RADIX-50: 6-character, uppercase-only symbol names (space=0, A-Z=1-
   26, $=27, .=28, 0-9=36-45; two characters -- 29,30,31,35 -- unused),
   3 characters packed per word as ((c1*50)+c2)*50+c3 (the "50" is
   octal, i.e. base 40 decimal).  C identifiers longer than 6 characters
   are simply truncated, and any character outside the RADIX-50 alphabet
   (starting with '_', ubiquitous in C names) is mapped to '.' -- a
   real, unavoidable lossy-compatibility limitation of this 1970s
   format, not a bug: RT-11's own linker has no other way to spell a
   global symbol name.

   "Formatted binary block" framing (every block below): a byte 1, a
   byte 0, a little-endian 16-bit length (covering everything except
   the trailing checksum byte), the data bytes themselves (whose first
   word is always a data-block-type code), and a checksum byte that is
   the negative of the sum of every preceding byte in the block.

   Symbol scope: only GLOBAL symbols can be represented at all -- RT-11
   object modules have an Internal Symbol Directory (ISD) block type
   for local symbols, but "the Linker does not support internal symbol
   tables ... if the Linker encounters an internal symbol entry while
   reading the GSD, it ignores it" (manual, section 2.2.1.3), so this
   writer does not bother emitting ISD blocks at all.  This is exactly
   right for C: a \`static\` symbol has no business being visible to a
   separate link anyway.

   Relocation model: RLD entries come in "direct" and "displaced" (PC-
   relative) pairs, each further split into three cases depending on
   what the reference resolves to -- Internal (same p-sect: the addend
   in the RLD entry itself *is* the target offset, no separate "plain
   vs additive" distinction needed), P-sect (a named p-sect other than
   the one currently being written: plain 12/14 if the offset is zero,
   additive 15/16 with an explicit constant otherwise), and Global (an
   external symbol: plain 2/4 if zero offset, additive 5/6 otherwise).
   What decides plain-vs-additive, and supplies the constant, is the
   word this writer puts into the section content itself -- see
   rel_apply_relocs, which has to fill those words in because ELF
   relocations keep their addend in a field of their own and leave the
   content empty.

   TXT block chunking: an RLD entry's displacement byte is only one
   byte (0-255), relative to the *immediately preceding* TXT block's own
   load address -- so section content is chunked into REL_TXT_CHUNK
   pieces well under that limit, each with its own load address, rather
   than emitted as one large blob.  */

#include "bfdlink.h"
#include <ctype.h>

#define REL_TXT_CHUNK 128

/* Data block type codes (manual, Table 2-1).  */
#define REL_BLK_GSD	1
#define REL_BLK_ENDGSD	2
#define REL_BLK_TXT	3
#define REL_BLK_RLD	4
#define REL_BLK_ENDMOD	6

/* GSD entry types (manual, Table 2-2).  */
#define REL_GSD_MODNAME	0
#define REL_GSD_PSECT	5
#define REL_GSD_GLOBAL	4

/* GSD Global Symbol Name flag bits (manual, Table 2-3).  */
#define REL_GFLAG_DEF	0x08	/* Bit 3: 1 = definition, 0 = reference.  */
#define REL_GFLAG_REL	0x20	/* Bit 5: 1 = relative value.  */

/* GSD P-sect Name flag bits (manual, Table 2-4).  */
#define REL_PFLAG_REL	0x20	/* Bit 5: 1 = relocatable p-sect.  */
#define REL_PFLAG_GBL	0x40	/* Bit 6: 1 = global scope.  */
#define REL_PFLAG_DATA	0x80	/* Bit 7: 1 = data (D), 0 = instruction (I).  */

/* RLD entry types (manual, Table 2-5).  */
#define REL_RLD_INTERNAL	1
#define REL_RLD_GLOBAL		2
#define REL_RLD_INTERNAL_DISP	3
#define REL_RLD_GLOBAL_DISP	4
#define REL_RLD_GLOBAL_ADD	5
#define REL_RLD_GLOBAL_ADD_DISP	6
#define REL_RLD_LOCCTR_DEF	7
#define REL_RLD_PSECT		12
#define REL_RLD_PSECT_DISP	14
#define REL_RLD_PSECT_ADD	15
#define REL_RLD_PSECT_ADD_DISP	16

/* ---- RADIX-50 ---- */

/* Value of one character in the RADIX-50 alphabet, or -1 if it has no
   representation (mapped to '.' by the caller before this is reached
   for anything but the initial classification).  */

static int
rad50_value (char c)
{
  if (c == ' ')
    return 0;
  if (c >= 'A' && c <= 'Z')
    return 1 + (c - 'A');
  if (c == '\$')
    return 27;
  if (c == '.')
    return 28;
  if (c >= '0' && c <= '9')
    return 36 + (c - '0');
  return -1;
}

/* Pack up to 6 characters of NAME into 4 bytes (2 little-endian
   RADIX-50 words) at OUT.  Longer names are truncated; characters
   outside the RADIX-50 alphabet (starting with the universal case,
   '_') are folded to '.'; lowercase letters are uppercased first.  */

static void
rad50_pack6 (const char *name, bfd_byte *out)
{
  char chars[6];
  size_t i, len;
  unsigned int word0, word1;

  len = name != NULL ? strlen (name) : 0;
  for (i = 0; i < 6; i++)
    {
      char c = (i < len) ? name[i] : ' ';
      int v;

      if (c >= 'a' && c <= 'z')
	c = (char) toupper ((unsigned char) c);
      v = rad50_value (c);
      if (v < 0)
	{
	  /* Not representable (e.g. '_', common in C names) -- fold to
	     '.', itself a valid RADIX-50 character.  */
	  c = '.';
	}
      chars[i] = c;
    }

  /* The "50" in the packing formula is octal (= 40 decimal); write it
     as decimal 40 directly rather than as a C literal that could be
     misread as octal 050.  */
  word0 = (unsigned int) (((rad50_value (chars[0]) * 40)
			    + rad50_value (chars[1])) * 40
			   + rad50_value (chars[2]));
  word1 = (unsigned int) (((rad50_value (chars[3]) * 40)
			    + rad50_value (chars[4])) * 40
			   + rad50_value (chars[5]));

  bfd_putl16 (word0, out);
  bfd_putl16 (word1, out + 2);
}

/* ---- Growable byte buffer, used to build one data block's payload
   (everything after the "1,0,length" framing prefix, i.e. starting
   with the data-block-type word) before it is checksummed and
   flushed.  ---- */

struct relbuf
{
  bfd_byte *data;
  size_t len;
  size_t cap;
};

static void
relbuf_init (struct relbuf *b)
{
  b->cap = 256;
  b->data = (bfd_byte *) xmalloc (b->cap);
  b->len = 0;
}

static void
relbuf_reserve (struct relbuf *b, size_t more)
{
  if (b->len + more > b->cap)
    {
      while (b->len + more > b->cap)
	b->cap *= 2;
      b->data = (bfd_byte *) xrealloc (b->data, b->cap);
    }
}

static void
relbuf_byte (struct relbuf *b, unsigned int v)
{
  relbuf_reserve (b, 1);
  b->data[b->len++] = (bfd_byte) v;
}

static void
relbuf_word (struct relbuf *b, unsigned int v)
{
  relbuf_reserve (b, 2);
  bfd_putl16 (v, b->data + b->len);
  b->len += 2;
}

static void
relbuf_name (struct relbuf *b, const char *name)
{
  relbuf_reserve (b, 4);
  rad50_pack6 (name, b->data + b->len);
  b->len += 4;
}

static void
relbuf_bytes (struct relbuf *b, const void *p, size_t n)
{
  relbuf_reserve (b, n);
  memcpy (b->data + b->len, p, n);
  b->len += n;
}

static void
relbuf_free (struct relbuf *b)
{
  free (b->data);
  b->data = NULL;
  b->len = b->cap = 0;
}

/* Write BUF (a complete data-block payload, starting with its type
   word) out to F as one "formatted binary block": the 1,0,length
   framing prefix, the payload itself, and a trailing checksum byte
   (the negative of the sum of every preceding byte).  Does not free or
   clear BUF -- callers that reuse one relbuf for several blocks (GSD
   entries, in particular) do that themselves.  */

static bool
relbuf_flush (FILE *f, const struct relbuf *b)
{
  bfd_byte prefix[4];
  unsigned int sum = 0;
  bfd_byte checksum;
  size_t i;

  bfd_putl16 ((unsigned int) (b->len + 4), prefix + 2);
  prefix[0] = 1;
  prefix[1] = 0;

  if (fwrite (prefix, 1, 4, f) != 4)
    return false;
  if (b->len != 0 && fwrite (b->data, 1, b->len, f) != b->len)
    return false;

  for (i = 0; i < 4; i++)
    sum += prefix[i];
  for (i = 0; i < b->len; i++)
    sum += b->data[i];
  checksum = (bfd_byte) (0x100 - (sum & 0xff));

  return fwrite (&checksum, 1, 1, f) == 1;
}

/* Write a single-word data block (ENDGSD or ENDMOD -- just a type
   code, no payload) directly, without needing a relbuf.  */

static bool
relbuf_flush_bare (FILE *f, unsigned int block_type)
{
  struct relbuf b;
  bool ok;

  relbuf_init (&b);
  relbuf_word (&b, block_type);
  ok = relbuf_flush (f, &b);
  relbuf_free (&b);
  return ok;
}

/* ---- The three p-sects this writer ever declares, matching this
   toolchain's fixed .text/.data/.bss model (plus the special .ABS.
   p-sect the manual says undefined global references must be declared
   under).  ---- */

enum rel_psect_kind { PSECT_TEXT, PSECT_DATA, PSECT_BSS, PSECT_ABS, PSECT_NONE };

struct rel_psect_info
{
  const char *name;
  asection *sec;	/* NULL for .ABS.  */
  unsigned int flags;
  /* Where this p-sect starts once the module is loaded.  A loader lays
     the three out end to end in this order, each rounded up to a word
     -- see layout() in this project's own libppu/ppuc_rel.c -- and a
     PC-relative word inside the module has to be right for that
     layout, because nothing patches it afterwards.  */
  bfd_vma base;
};

/* Which p-sect a relocation's target symbol lives in, or PSECT_NONE for
   a symbol this module does not define.

   Note that this asks about the symbol's *section*, not about whether
   it is a section symbol.  It has to: ELF keeps a relocation against a
   global symbol even when the definition is right there in the same
   module, and the loader on the other end cannot resolve a reference by
   name (libppu's ppuc_rel.c rejects the Global entry types outright).
   Resolving it here to the p-sect it actually falls in is both what the
   loader can use and what a.out used to arrive at by itself, since its
   \`-r\` link reduced those references to section-relative ones.  */

static enum rel_psect_kind
rel_classify_symbol (asymbol *sym, struct rel_psect_info *psects)
{
  asection *sec = bfd_asymbol_section (sym);
  int i;

  for (i = 0; i < 3; i++)
    if (psects[i].sec != NULL && sec == psects[i].sec)
      return (enum rel_psect_kind) i;

  if (bfd_is_abs_section (sec))
    return PSECT_ABS;

  return PSECT_NONE;
}

/* Put the value of each relocation into the section content.

   ELF relocations keep their addend in a field of their own and leave
   the relocated word empty, so somebody has to write it, and here that
   somebody is this writer: of the RLD entry types it emits, a loader
   patches only the direct ones, and treats a displaced (PC-relative)
   entry as already correct -- which it can, since a displacement
   between two points of the same module does not depend on where the
   module lands.  The value is the one the module would have if it were
   loaded at 0, with the p-sects laid out as rel_psect_info::base says,
   which is exactly how it will be loaded.

   The word also decides how the RLD entry itself comes out: zero means
   the plain entry type, anything else the additive one with the
   constant spelled out.  */

static void
rel_apply_relocs (bfd_byte *contents, bfd_size_type size,
		  arelent **relpp, long relcount,
		  struct rel_psect_info *psect,
		  struct rel_psect_info *psects)
{
  long r;

  for (r = 0; r < relcount; r++)
    {
      arelent *rel = relpp[r];
      asymbol *sym = *rel->sym_ptr_ptr;
      enum rel_psect_kind kind = rel_classify_symbol (sym, psects);
      bool pcrel = rel->howto != NULL && rel->howto->pc_relative;
      bfd_vma target = sym->value + rel->addend;
      bfd_vma word;

      if (rel->address + 2 > size)
	continue;

      if (kind != PSECT_NONE && kind != PSECT_ABS)
	target += psects[(int) kind].base;

      if (pcrel)
	/* A PC-relative addend already carries the -2 for this machine's
	   habit of reaching such an operand from the word after it (see
	   include/elf/pdp11.h), and the displacement is measured from
	   that same following word -- so the two cancel and what is left
	   is the distance between the two words.  */
	word = target - (psect->base + rel->address);
      else
	word = target;

      bfd_putl16 (word & 0xffff, contents + rel->address);
    }
}

/* Emit the GSD block(s): module name, then each p-sect immediately
   followed by the global symbols defined within it (manual: "all
   global symbol definitions pertaining to [a p-sect] must appear ...
   before another p-sect name is declared"), then .ABS. followed by
   every undefined (referenced-but-not-defined) global.  A single GSD
   block is enough here -- nothing in this module's expected symbol
   count is likely to overflow one formatted-binary-block's 16-bit
   length, and if it ever does, bfd_write below will simply fail
   loudly rather than silently truncate.  */

static bool
rel_write_gsd (FILE *f, const char *modname, asymbol **syms, long symcount,
	       struct rel_psect_info *psects)
{
  struct relbuf b;
  int i;
  long s;

  relbuf_init (&b);
  relbuf_word (&b, REL_BLK_GSD);

  relbuf_name (&b, modname);
  relbuf_word (&b, REL_GSD_MODNAME);
  relbuf_word (&b, 0);

  for (i = 0; i < 3; i++)
    {
      relbuf_name (&b, psects[i].name);
      relbuf_word (&b, (unsigned int) (REL_GSD_PSECT | (psects[i].flags << 8)));
      relbuf_word (&b, (unsigned int) psects[i].sec->size);

      for (s = 0; s < symcount; s++)
	{
	  asymbol *sym = syms[s];

	  if ((sym->flags & (BSF_GLOBAL | BSF_WEAK)) == 0)
	    continue;
	  if (bfd_asymbol_section (sym) != psects[i].sec)
	    continue;

	  relbuf_name (&b, bfd_asymbol_name (sym));
	  relbuf_word (&b, (unsigned int)
			    (REL_GSD_GLOBAL
			     | ((REL_GFLAG_DEF | REL_GFLAG_REL) << 8)));
	  relbuf_word (&b, (unsigned int) sym->value);
	}
    }

  /* .ABS.: declare it (size 0, absolute -- REL_PFLAG_REL left clear),
     then every undefined global reference under it, per the manual.  */
  relbuf_name (&b, ".ABS.");
  relbuf_word (&b, (unsigned int) (REL_GSD_PSECT | (REL_PFLAG_GBL << 8)));
  relbuf_word (&b, 0);

  for (s = 0; s < symcount; s++)
    {
      asymbol *sym = syms[s];

      if (!bfd_is_und_section (bfd_asymbol_section (sym)))
	continue;
      if ((sym->flags & BSF_SECTION_SYM) != 0)
	continue;

      relbuf_name (&b, bfd_asymbol_name (sym));
      relbuf_word (&b, (unsigned int) (REL_GSD_GLOBAL | (0 << 8)));
      relbuf_word (&b, 0);
    }

  {
    bool ok = relbuf_flush (f, &b);
    relbuf_free (&b);
    return ok && relbuf_flush_bare (f, REL_BLK_ENDGSD);
  }
}

/* Emit the RLD/TXT block sequence for one p-sect's content: an initial
   Location Counter Definition, then TXT chunks of at most
   REL_TXT_CHUNK bytes each, each optionally followed by an RLD block
   covering the relocations that fall within it.  */

static bool
rel_write_section (FILE *f, bfd *ibfd, struct rel_psect_info *psect,
		    struct rel_psect_info *psects, asymbol **syms)
{
  asection *sec = psect->sec;
  bfd_size_type size = sec->size;
  bfd_byte *contents = NULL;
  arelent **relpp = NULL;
  long relcount = 0;
  bfd_size_type chunk_start;
  struct relbuf b;
  bool ok = true;

  /* Location Counter Definition: establishes the current p-sect for
     the TXT/RLD blocks that follow (manual, 2.2.4.7).  Its own
     displacement byte is unused (always 0).  */
  relbuf_init (&b);
  relbuf_word (&b, REL_BLK_RLD);
  relbuf_byte (&b, 0);
  relbuf_byte (&b, REL_RLD_LOCCTR_DEF);
  relbuf_name (&b, psect->name);
  relbuf_word (&b, 0);
  ok = relbuf_flush (f, &b);
  relbuf_free (&b);
  if (!ok || size == 0)
    return ok;

  contents = (bfd_byte *) xmalloc (size);
  if (!bfd_get_section_contents (ibfd, sec, contents, 0, size))
    fatal (_("%P: %s: cannot read section \`%pA': %E\n"),
	   bfd_get_filename (ibfd), sec);

  if ((sec->flags & SEC_RELOC) != 0 && sec->reloc_count != 0)
    {
      long relsize = bfd_get_reloc_upper_bound (ibfd, sec);

      if (relsize < 0)
	fatal (_("%P: %s: cannot get relocation size for \`%pA': %E\n"),
	       bfd_get_filename (ibfd), sec);
      if (relsize > 0)
	{
	  relpp = (arelent **) xmalloc ((size_t) relsize);
	  relcount = bfd_canonicalize_reloc (ibfd, sec, relpp, syms);
	  if (relcount < 0)
	    fatal (_("%P: %s: cannot read relocations for \`%pA': %E\n"),
		   bfd_get_filename (ibfd), sec);
	}
    }

  rel_apply_relocs (contents, size, relpp, relcount, psect, psects);

  for (chunk_start = 0; chunk_start < size; chunk_start += REL_TXT_CHUNK)
    {
      bfd_size_type chunk_len = size - chunk_start;
      long r;

      if (chunk_len > REL_TXT_CHUNK)
	chunk_len = REL_TXT_CHUNK;

      relbuf_init (&b);
      relbuf_word (&b, REL_BLK_TXT);
      relbuf_word (&b, (unsigned int) chunk_start);
      relbuf_bytes (&b, contents + chunk_start, (size_t) chunk_len);
      ok = relbuf_flush (f, &b);
      relbuf_free (&b);
      if (!ok)
	goto out;

      relbuf_init (&b);
      relbuf_word (&b, REL_BLK_RLD);

      for (r = 0; r < relcount; r++)
	{
	  arelent *rel = relpp[r];
	  bfd_vma addr = rel->address;
	  unsigned int disp;
	  bool pcrel;
	  unsigned int constant;
	  asymbol *sym;
	  enum rel_psect_kind kind;

	  if (addr < chunk_start || addr >= chunk_start + chunk_len)
	    continue;

	  disp = (unsigned int) (addr - chunk_start);
	  pcrel = rel->howto != NULL && rel->howto->pc_relative;
	  constant = bfd_getl16 (contents + addr);
	  sym = *rel->sym_ptr_ptr;
	  kind = rel_classify_symbol (sym, psects);

	  /* rel_apply_relocs wrote the target's address in the loaded
	     layout (.text at 0, .data right after it, .bss after that),
	     but a REL constant is relative to the *p-sect* the entry
	     names -- the loader adds that p-sect's own base to it.  Take
	     the target p-sect's start back out, or a reference into
	     .data ends up relocated by .data's offset twice (harmless
	     for .text, whose start is 0 -- which is how this went
	     unnoticed until the first PPU program with a .data jump
	     table).  Displaced (PC-relative) entries keep the word as
	     written: it is a distance within the module, and the loader
	     leaves it alone.  */
	  if (!pcrel && kind != PSECT_NONE && kind != PSECT_ABS)
	    constant = (constant - (unsigned int) psects[(int) kind].base)
		       & 0xffff;

	  if (kind == PSECT_NONE)
	    {
	      /* A real external symbol.  */
	      const char *name = bfd_asymbol_name (sym);

	      if (constant == 0)
		{
		  relbuf_byte (&b, disp);
		  relbuf_byte (&b, pcrel ? REL_RLD_GLOBAL_DISP : REL_RLD_GLOBAL);
		  relbuf_name (&b, name);
		}
	      else
		{
		  relbuf_byte (&b, disp);
		  relbuf_byte (&b, pcrel
				    ? REL_RLD_GLOBAL_ADD_DISP : REL_RLD_GLOBAL_ADD);
		  relbuf_name (&b, name);
		  relbuf_word (&b, constant);
		}
	    }
	  else if (kind == (enum rel_psect_kind) (psect - psects))
	    {
	      /* Same p-sect as the one we're currently writing.  */
	      relbuf_byte (&b, disp);
	      relbuf_byte (&b, pcrel
				? REL_RLD_INTERNAL_DISP : REL_RLD_INTERNAL);
	      relbuf_word (&b, constant);
	    }
	  else
	    {
	      /* A different p-sect (including .ABS., kind == PSECT_ABS,
		 which has no rel_psect_info entry of its own -- use its
		 fixed name directly).  */
	      const char *pname
		= (kind == PSECT_ABS) ? ".ABS." : psects[(int) kind].name;

	      if (constant == 0)
		{
		  relbuf_byte (&b, disp);
		  relbuf_byte (&b, pcrel ? REL_RLD_PSECT_DISP : REL_RLD_PSECT);
		  relbuf_name (&b, pname);
		}
	      else
		{
		  relbuf_byte (&b, disp);
		  relbuf_byte (&b, pcrel
				    ? REL_RLD_PSECT_ADD_DISP : REL_RLD_PSECT_ADD);
		  relbuf_name (&b, pname);
		  relbuf_word (&b, constant);
		}
	    }
	}

      if (b.len > 2)
	ok = relbuf_flush (f, &b);
      relbuf_free (&b);
      if (!ok)
	goto out;
    }

 out:
  free (contents);
  free (relpp);
  return ok;
}

/* Read the just-linked (\`-r\`) file back with ordinary BFD
   calls and write it out as an RT-11 native relocatable object module
   (GSD/TXT/RLD/ENDMOD).  See the big block comment above for the full
   design.  */

static bool
pdp11rel_write (bfd *ibfd, const char *filename)
{
  FILE *f;
  asymbol **syms = NULL;
  long symcount;
  struct rel_psect_info psects[3];
  const char *base;
  char *tmpname;
  char modname[7];
  size_t i;
  bool ok;

  psects[PSECT_TEXT].name = ".text";
  psects[PSECT_TEXT].sec = bfd_get_section_by_name (ibfd, ".text");
  psects[PSECT_TEXT].flags = REL_PFLAG_REL | REL_PFLAG_GBL;
  psects[PSECT_DATA].name = ".data";
  psects[PSECT_DATA].sec = bfd_get_section_by_name (ibfd, ".data");
  psects[PSECT_DATA].flags = REL_PFLAG_REL | REL_PFLAG_GBL | REL_PFLAG_DATA;
  psects[PSECT_BSS].name = ".bss";
  psects[PSECT_BSS].sec = bfd_get_section_by_name (ibfd, ".bss");
  psects[PSECT_BSS].flags = REL_PFLAG_REL | REL_PFLAG_GBL | REL_PFLAG_DATA;

  for (i = 0; i < 3; i++)
    if (psects[i].sec == NULL)
      fatal (_("%P: %s: missing \`%s' section after linking\n"),
	     filename, psects[i].name);

  /* The layout the module will be loaded at, which the words this
     writer puts in the content have to agree with; see
     rel_psect_info::base.  */
  psects[PSECT_TEXT].base = 0;
  psects[PSECT_DATA].base
    = (psects[PSECT_TEXT].sec->size + 1) & ~(bfd_vma) 1;
  psects[PSECT_BSS].base
    = psects[PSECT_DATA].base + ((psects[PSECT_DATA].sec->size + 1)
				 & ~(bfd_vma) 1);

  {
    long storage = bfd_get_symtab_upper_bound (ibfd);

    if (storage < 0)
      fatal (_("%P: %s: cannot get symbol table size: %E\n"), filename);
    if (storage > 0)
      {
	syms = (asymbol **) xmalloc ((size_t) storage);
	symcount = bfd_canonicalize_symtab (ibfd, syms);
	if (symcount < 0)
	  fatal (_("%P: %s: cannot read symbol table: %E\n"), filename);
      }
    else
      symcount = 0;
  }

  /* Module name: the output file's own base name, RADIX-50 truncated
     like everything else here -- there is no more meaningful choice
     for a module built by \`ld -r\` from multiple inputs.  */
  base = lbasename (filename);
  for (i = 0; i < 6 && base[i] != '\0' && base[i] != '.'; i++)
    modname[i] = base[i];
  modname[i] = '\0';

  /* Written to a temporary file and renamed over the original, never
     to \`filename\` directly: ibfd is still open on that same path and
     rel_write_section below reads each section's contents and
     relocations out of it as it goes.  Opening it "wb" here truncates
     it under that reader, and every read after the point BFD has
     cached fails with "file truncated" -- so whether the link worked
     depended on file size and section order.  Seen as an intermittent
     link failure on a PPU program that had merely grown a little
     (2026-09-09).  */
  tmpname = (char *) xmalloc (strlen (filename) + 5);
  sprintf (tmpname, "%s.tmp", filename);

  f = fopen (tmpname, "wb");
  if (f == NULL)
    fatal (_("%P: %s: cannot create RT-11 REL output: %s\n"),
	   tmpname, strerror (errno));

  ok = rel_write_gsd (f, modname, syms, symcount, psects);
  for (i = 0; ok && i < 3; i++)
    ok = rel_write_section (f, ibfd, &psects[i], psects, syms);
  if (ok)
    ok = relbuf_flush_bare (f, REL_BLK_ENDMOD);

  if (fclose (f) != 0)
    ok = false;
  if (ok && rename (tmpname, filename) != 0)
    {
      fatal (_("%P: %s: cannot rename over the linked output: %s\n"),
	     tmpname, strerror (errno));
      ok = false;
    }
  if (!ok)
    unlink (tmpname);
  free (tmpname);
  free (syms);
  return ok;
}

/* This emulation's OUTPUT_FORMAT is the ordinary object format, same as
   plain pdp11rt11 -- deliberately, and meant to be used with \`-r\`.
   Linking goes through that backend's own relocatable-link path,
   producing exactly the file \`ld -r -m pdp11rt11\` would.  Once that
   file is fully written to disk, this hook reopens it, reads its
   symbols/relocations/contents back with ordinary BFD calls, and
   repacks all of that into the RT-11 native relocatable object format
   in place -- see
   pdp11rel_write above.  This hook runs from ldmain.c's
   ldemul_after_close_output(), right after ldwrite()'s bfd_close()
   finishes writing that a.out file to the user's requested output
   path.

   Only runs for -r/-Ur (bfd_link_relocatable) -- the opposite of
   pdp11rt11sav's guard.  A normal, non-relocatable final link has
   nothing meaningful to convert here: RT-11's native object format is
   for feeding a *later* link, not for a finished, runnable program
   (that role belongs to SAV, produced by pdp11rt11sav instead).  */

static void
gld${EMULATION_NAME}_after_close_output (void)
{
  bfd *ibfd;

  if (!bfd_link_relocatable (&link_info))
    return;

  ibfd = bfd_openr (output_filename, "${OUTPUT_FORMAT}");
  if (ibfd == NULL)
    fatal (_("%P: %s: cannot reopen linked ${OUTPUT_FORMAT} output "
	     "for RT-11 REL conversion: %E\n"), output_filename);
  if (!bfd_check_format (ibfd, bfd_object))
    fatal (_("%P: %s: not recognized as ${OUTPUT_FORMAT} after linking: "
	     "%E\n"), output_filename);

  if (!pdp11rel_write (ibfd, output_filename))
    fatal (_("%P: %s: writing RT-11 REL output failed: %E\n"),
	   output_filename);

  if (!bfd_close (ibfd))
    fatal (_("%P: %s: final close failed: %E\n"), output_filename);
}

/* --- \end{pdp11rt11rel.em} */

EOF

LDEMUL_AFTER_CLOSE_OUTPUT=gld"$EMULATION_NAME"_after_close_output
