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
# This is pdp11.em (same PDP11-Unix-compatible --omagic/--imagic option
# handling as the plain pdp11/pdp11rt11 emulations) plus one extra hook:
# after_close_output.  See the big comment on that function below for why
# it exists.

fragment <<EOF

/* --- \begin{pdp11rt11sav.em} */
#include "libiberty.h"
#include "getopt.h"
#include <errno.h>

static void
gld${EMULATION_NAME}_before_parse (void)
{
  ldfile_set_output_arch ("`echo ${ARCH}`", bfd_arch_unknown);
  /* for PDP11 Unix compatibility, default to --omagic */
  config.magic_demand_paged = false;
  config.text_read_only = false;
}

/* PDP11 specific options.  */
#define OPTION_IMAGIC 301

static void
gld${EMULATION_NAME}_add_options
  (int ns ATTRIBUTE_UNUSED,
   char **shortopts,
   int nl,
   struct option **longopts,
   int nrl ATTRIBUTE_UNUSED,
   struct option **really_longopts ATTRIBUTE_UNUSED)
{
  static const char xtra_short[] = "z";
  static const struct option xtra_long[] =
  {
    {"imagic", no_argument, NULL, OPTION_IMAGIC},
    {NULL, no_argument, NULL, 0}
  };

  *shortopts = (char *) xrealloc (*shortopts, ns + sizeof (xtra_short));
  memcpy (*shortopts + ns, &xtra_short, sizeof (xtra_short));
  *longopts
    = xrealloc (*longopts, nl * sizeof (struct option) + sizeof (xtra_long));
  memcpy (*longopts + nl, &xtra_long, sizeof (xtra_long));
}

static void
gld${EMULATION_NAME}_list_options (FILE *file)
{
  fprintf (file, _("  -N, --omagic   Do not make text readonly, do not page align data (default)\n"));
  fprintf (file, _("  -n, --nmagic   Make text readonly, align data to next page\n"));
  fprintf (file, _("  -z, --imagic   Make text readonly, separate instruction and data spaces\n"));
  fprintf (file, _("  --no-omagic    Equivalent to --nmagic\n"));
}

static bool
gld${EMULATION_NAME}_handle_option (int optc)
{
  switch (optc)
    {
    default:
      return false;

    case 'z':
    case OPTION_IMAGIC:
      link_info.separate_code = 1;
      /* The --imagic format causes the .text and .data sections to occupy the
	 same memory addresses in separate spaces, so don't check overlap. */
      command_line.check_section_addresses = 0;
      break;
    }

  return true;
}

/* We need a special case to prepare an additional linker script for option
 * --imagic where the .data section starts at address 0 rather than directly
 * following the .text section or being aligned to the next page after the
 * .text section. */
static char *
gld${EMULATION_NAME}_get_script (int *isfile)
EOF

if test x"$COMPILE_IN" = xyes
then
# Scripts compiled in.

# sed commands to quote an ld script as a C string.
sc="-f ${srcdir}/emultempl/stringify.sed"

fragment <<EOF
{
  *isfile = 0;

  if (bfd_link_relocatable (&link_info) && config.build_constructors)
    return
EOF
sed $sc ldscripts/${EMULATION_NAME}.xu			>> e${EMULATION_NAME}.c
echo '  ; else if (bfd_link_relocatable (&link_info)) return' >> e${EMULATION_NAME}.c
sed $sc ldscripts/${EMULATION_NAME}.xr			>> e${EMULATION_NAME}.c
echo '  ; else if (link_info.separate_code) return'	>> e${EMULATION_NAME}.c
sed $sc ldscripts/${EMULATION_NAME}.xe			>> e${EMULATION_NAME}.c
echo '  ; else if (!config.text_read_only) return'	>> e${EMULATION_NAME}.c
sed $sc ldscripts/${EMULATION_NAME}.xbn			>> e${EMULATION_NAME}.c
echo '  ; else if (!config.magic_demand_paged) return'	>> e${EMULATION_NAME}.c
sed $sc ldscripts/${EMULATION_NAME}.xn			>> e${EMULATION_NAME}.c
echo '  ; else return'					>> e${EMULATION_NAME}.c
sed $sc ldscripts/${EMULATION_NAME}.x			>> e${EMULATION_NAME}.c
echo '; }'						>> e${EMULATION_NAME}.c

else
# Scripts read from the filesystem.

fragment <<EOF
{
  *isfile = 1;

  if (bfd_link_relocatable (&link_info) && config.build_constructors)
    return "ldscripts/${EMULATION_NAME}.xu";
  else if (bfd_link_relocatable (&link_info))
    return "ldscripts/${EMULATION_NAME}.xr";
  else if (link_info.separate_code)
    return "ldscripts/${EMULATION_NAME}.xe";
  else if (!config.text_read_only)
    return "ldscripts/${EMULATION_NAME}.xbn";
  else if (!config.magic_demand_paged)
    return "ldscripts/${EMULATION_NAME}.xn";
  else
    return "ldscripts/${EMULATION_NAME}.x";
}
EOF
fi

fragment <<EOF

/* This emulation's OUTPUT_FORMAT is "a.out-pdp11", same as plain
   pdp11rt11 -- deliberately.  a.out-pdp11 has its own specialized,
   proven-correct relocation-resolution path (pdp11_aout_link_input_section
   in bfd/pdp11.c); the generic BFD final-link path that a genuinely
   write-only format like sav-pdp11 would otherwise have to fall back to
   does not correctly reproduce it (confirmed on something as simple as a
   string-constant address reference).  So rather than link straight to
   sav-pdp11 and risk wrong relocated values, this emulation links a real,
   correct a.out-pdp11 file first -- exactly the same file
   \`ld -m pdp11rt11\` would produce -- and then, once that file is
   completely written to disk, converts it to the RT-11 SAV format in
   place.  That second step is relocation-free: everything in an a.out
   EXEC_P file's section contents is already final, absolute bytes, so
   converting it to sav-pdp11 is just a repack, the same one
   \`objcopy -O sav-pdp11\` already does correctly.  This hook runs from
   ldmain.c's ldemul_after_close_output(), right after ldwrite()'s
   bfd_close() finishes writing that a.out file to the user's requested
   output path.

   Skipped entirely for -r/-Ur (bfd_link_relocatable): that output is a
   relocatable a.out-pdp11 object meant to be fed into a later link, not
   a finished program, and sav-pdp11 has no room for the symbols/relocs
   such an object needs to carry -- converting it here would silently
   produce a file that looks superficially like a SAV image but has lost
   everything a subsequent link depends on.  */

static void
gld${EMULATION_NAME}_after_close_output (void)
{
  bfd *ibfd, *obfd;
  asection *is;
  char *tmp_filename;

  if (bfd_link_relocatable (&link_info))
    return;

  tmp_filename = concat (output_filename, ".sav-tmp", (const char *) NULL);

  ibfd = bfd_openr (output_filename, "a.out-pdp11");
  if (ibfd == NULL)
    fatal (_("%P: %s: cannot reopen linked a.out-pdp11 output "
	     "for RT-11 SAV conversion: %E\n"), output_filename);
  if (!bfd_check_format (ibfd, bfd_object))
    fatal (_("%P: %s: not recognized as a.out-pdp11 after linking: "
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

  if (rename (tmp_filename, output_filename) != 0)
    fatal (_("%P: cannot rename %s to %s: %s\n"),
	   tmp_filename, output_filename, strerror (errno));

  free (tmp_filename);
}

/* --- \end{pdp11rt11sav.em} */

EOF

LDEMUL_BEFORE_PARSE=gld"$EMULATION_NAME"_before_parse
LDEMUL_ADD_OPTIONS=gld"$EMULATION_NAME"_add_options
LDEMUL_HANDLE_OPTION=gld"$EMULATION_NAME"_handle_option
LDEMUL_LIST_OPTIONS=gld"$EMULATION_NAME"_list_options
LDEMUL_GET_SCRIPT=gld"$EMULATION_NAME"_get_script
LDEMUL_AFTER_CLOSE_OUTPUT=gld"$EMULATION_NAME"_after_close_output
