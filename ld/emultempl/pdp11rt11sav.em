# This shell script emits a C file. -*- C -*-
#   Copyright (C) 2006-2026 Free Software Foundation, Inc.
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
# emulation does, plus one hook, after_close_output.  See the comment on
# that function for why it exists.  (It used to carry a copy of
# emultempl/pdp11.em's option handling and script selection as well,
# because the emulation was built on the generic template rather than
# the ELF one; elf.em does all of that.)

fragment <<EOF

/* --- \begin{pdp11rt11sav.em} */
#include "libiberty.h"
#include <errno.h>

/* This emulation's OUTPUT_FORMAT is the ordinary object format, the same
   as plain pdp11rt11, and not "sav-pdp11" -- deliberately.  That backend
   has a real relocation-resolution path; the generic BFD final-link path
   that a genuinely write-only format like sav-pdp11 would otherwise have
   to fall back to does not correctly reproduce it (confirmed on
   something as simple as a string-constant address reference).  So
   rather than link straight to sav-pdp11 and risk wrong relocated
   values, this emulation links a real, correct ${OUTPUT_FORMAT} file
   first -- exactly the same file \`ld -m pdp11rt11\` would produce -- and
   then, once that file is completely written to disk, converts it to the
   RT-11 SAV format in place.  That second step is relocation-free:
   everything in a linked executable's section contents is already final,
   absolute bytes, so converting it to sav-pdp11 is just a repack, the
   same one \`objcopy -O sav-pdp11\` already does correctly.  This hook
   runs from ldmain.c's ldemul_after_close_output(), right after
   ldwrite()'s bfd_close() finishes writing that file to the user's
   requested output path.

   Skipped entirely for -r/-Ur (bfd_link_relocatable): that output is a
   relocatable object meant to be fed into a later link, not a finished
   program, and sav-pdp11 has no room for the symbols/relocs such an
   object needs to carry -- converting it here would silently produce a
   file that looks superficially like a SAV image but has lost everything
   a subsequent link depends on.  */

static void
gld${EMULATION_NAME}_after_close_output (void)
{
  bfd *ibfd, *obfd;
  asection *is;
  char *tmp_filename;

  if (bfd_link_relocatable (&link_info))
    return;

  tmp_filename = concat (output_filename, ".sav-tmp", (const char *) NULL);

  ibfd = bfd_openr (output_filename, "${OUTPUT_FORMAT}");
  if (ibfd == NULL)
    fatal (_("%P: %s: cannot reopen linked ${OUTPUT_FORMAT} output "
	     "for RT-11 SAV conversion: %E\n"), output_filename);
  if (!bfd_check_format (ibfd, bfd_object))
    fatal (_("%P: %s: not recognized as ${OUTPUT_FORMAT} after linking: "
	     "%E\n"), output_filename);

  obfd = bfd_openw (tmp_filename, "sav-pdp11");
  if (obfd == NULL)
    fatal (_("%P: %s: cannot create RT-11 SAV output: %E\n"), tmp_filename);

  bfd_set_format (obfd, bfd_object);
  bfd_set_arch_mach (obfd, bfd_get_arch (ibfd), bfd_get_mach (ibfd));
  bfd_set_start_address (obfd, bfd_get_start_address (ibfd));

  /* Two passes: bfd_set_section_contents() below marks the output bfd's
     output_has_begun once the first byte is written, and every
     bfd_make_section_*() call refuses to run after that point.  So every
     output section has to exist before any contents get written at
     all.  */
  for (is = ibfd->sections; is != NULL; is = is->next)
    {
      asection *os;

      if ((is->flags & SEC_ALLOC) == 0)
	continue;

      os = bfd_make_section_anyway_with_flags (obfd,
						bfd_section_name (is),
						is->flags);
      if (os == NULL)
	fatal (_("%P: %s: cannot create section \`%pA' in RT-11 SAV "
		 "output: %E\n"), tmp_filename, is);

      if (!bfd_set_section_size (os, is->size))
	fatal (_("%P: %s: cannot size section \`%pA' in RT-11 SAV "
		 "output: %E\n"), tmp_filename, is);
      os->vma = is->vma;
      os->lma = is->lma;
    }

  for (is = ibfd->sections; is != NULL; is = is->next)
    {
      asection *os;

      if ((is->flags & SEC_HAS_CONTENTS) == 0 || is->size == 0)
	continue;

      os = bfd_get_section_by_name (obfd, bfd_section_name (is));
      if (os != NULL)
	{
	  void *contents = xmalloc (is->size);

	  if (!bfd_get_section_contents (ibfd, is, contents, 0, is->size))
	    fatal (_("%P: %s: cannot read section \`%pA': %E\n"),
		   output_filename, is);
	  if (!bfd_set_section_contents (obfd, os, contents, 0, is->size))
	    fatal (_("%P: %s: cannot write section \`%pA' to RT-11 "
		     "SAV output: %E\n"), tmp_filename, is);
	  free (contents);
	}
    }

  if (!bfd_close (obfd))
    fatal (_("%P: %s: final close of RT-11 SAV output failed: %E\n"),
	   tmp_filename);

  if (!bfd_close (ibfd))
    fatal (_("%P: %s: final close failed: %E\n"), output_filename);

  /* The linked file is still sitting there under the name the SAV image
     is about to take, and on Windows rename() will not write over an
     existing file the way it does everywhere else -- "cannot rename
     hello.sav.sav-tmp to hello.sav: File exists".  Removing it first
     costs nothing on a host where rename() would have done it.  */
  unlink (output_filename);

  if (rename (tmp_filename, output_filename) != 0)
    fatal (_("%P: cannot rename %s to %s: %s\n"),
	   tmp_filename, output_filename, strerror (errno));

  free (tmp_filename);
}

/* --- \end{pdp11rt11sav.em} */

EOF

LDEMUL_AFTER_CLOSE_OUTPUT=gld"$EMULATION_NAME"_after_close_output
