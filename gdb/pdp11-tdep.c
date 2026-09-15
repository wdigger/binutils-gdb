/* Target-dependent code for the DEC PDP-11.

   Copyright (C) 2025 Free Software Foundation, Inc.

   This file is part of GDB.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.  */

#include "arch-utils.h"
#include "dis-asm.h"
#include "dwarf2/frame.h"
#include "extract-store-integer.h"
#include "frame.h"
#include "frame-base.h"
#include "frame-unwind.h"
#include "gdbcore.h"
#include "gdbtypes.h"
#include "objfiles.h"
#include "osabi.h"
#include "regcache.h"
#include "symtab.h"
#include "trad-frame.h"
#include "value.h"

/* The register file: eight 16-bit general registers, of which R6 is the
   stack pointer and R7 the program counter, plus the processor status
   word.  R5 is the frame pointer by convention, not by hardware.

   These numbers are also the DWARF register numbers -- the compiler
   numbers R0 to R7 as 0 to 7, and names 7 as the return address column --
   so no mapping is needed between the two.  */

enum pdp11_regnum
{
  PDP11_R0_REGNUM = 0,
  PDP11_R1_REGNUM = 1,
  PDP11_FP_REGNUM = 5,
  PDP11_SP_REGNUM = 6,
  PDP11_PC_REGNUM = 7,
  PDP11_PS_REGNUM = 8,
  PDP11_NUM_REGS = 9
};

/* BPT, the breakpoint trap, which goes through vector 014.  */

constexpr gdb_byte pdp11_break_insn[] = { 0x03, 0x00 };

typedef BP_MANIPULATION (pdp11_break_insn) pdp11_breakpoint;

/* Instructions the prologue is built out of.  Written the way the
   assembler writes them, in octal, because that is how every PDP-11
   listing and manual gives them.

   MOV_RN_PUSH is "mov rN,-(sp)" without its register field; the field is
   bits 6 to 8.  */

#define PDP11_MOV_RN_PUSH  0010046
#define PDP11_MOV_SP_R5    0010605
#define PDP11_ADD_IMM_SP   0062706
#define PDP11_SUB_IMM_SP   0162706
#define PDP11_JSR_PC       0004700

/* Any prologue longer than this is not one.  */

#define PDP11_MAX_PROLOGUE 32

struct pdp11_frame_cache
{
  /* The canonical frame address: the stack pointer of the caller, just
     before the call pushed the return address.  */
  CORE_ADDR cfa;

  /* Start of the function this frame is in, or zero if unknown.  */
  CORE_ADDR func;

  /* True once the prologue has set R5 up as a frame pointer.  */
  bool has_frame_pointer;

  /* How far the stack pointer has moved below the CFA.  */
  int sp_offset;

  /* Where each register was saved, or -1.  */
  trad_frame_saved_reg *saved_regs;
};

/* Implement the "register_name" gdbarch method.  */

static const char *
pdp11_register_name (struct gdbarch *gdbarch, int regnum)
{
  static const char *const register_names[] =
  {
    "r0", "r1", "r2", "r3", "r4", "r5", "sp", "pc", "ps"
  };

  static_assert (ARRAY_SIZE (register_names) == PDP11_NUM_REGS);
  return register_names[regnum];
}

/* Implement the "register_type" gdbarch method.  */

static struct type *
pdp11_register_type (struct gdbarch *gdbarch, int regnum)
{
  if (regnum == PDP11_PC_REGNUM)
    return builtin_type (gdbarch)->builtin_func_ptr;
  if (regnum == PDP11_SP_REGNUM || regnum == PDP11_FP_REGNUM)
    return builtin_type (gdbarch)->builtin_data_ptr;
  return builtin_type (gdbarch)->builtin_uint16;
}

/* Read the instruction word at ADDR.  */

static unsigned int
pdp11_read_word (struct gdbarch *gdbarch, CORE_ADDR addr)
{
  return read_code_unsigned_integer (addr, 2, gdbarch_byte_order (gdbarch));
}

/* Walk the prologue of the function starting at FUNC, stopping at LIMIT
   or at the first instruction that is not part of one.  Returns the
   address after the prologue, and fills CACHE in if it is not null.

   The compiler builds a frame here in up to three steps, any of which
   may be absent:

	mov	r5,-(sp)	save the caller's frame pointer
	mov	sp,r5		make this frame's
	add	$-N,sp		reserve N bytes of locals

   with -fomit-frame-pointer, which this project's own code is built
   with, only the third appears.  Callee-saved registers are pushed
   before the frame is set up, one "mov rN,-(sp)" each.

   This is the fallback.  Anything compiled with -g carries call frame
   information, and the DWARF unwinder registered alongside this one gets
   to it first and is exact; what is left for this is the startup code,
   the operating system, and anything hand-written in assembler.  */

static CORE_ADDR
pdp11_analyze_prologue (struct gdbarch *gdbarch, CORE_ADDR func,
			CORE_ADDR limit, struct pdp11_frame_cache *cache)
{
  CORE_ADDR pc = func;
  CORE_ADDR end = func + PDP11_MAX_PROLOGUE;
  int offset = 0;

  if (limit < end)
    end = limit;

  while (pc + 2 <= end)
    {
      unsigned int insn = pdp11_read_word (gdbarch, pc);

      if ((insn & ~(unsigned) 0000700) == PDP11_MOV_RN_PUSH)
	{
	  /* mov rN,-(sp) -- a saved register, the frame pointer among
	     them when there is one.  */
	  int regnum = (insn >> 6) & 7;

	  offset += 2;
	  if (cache != NULL)
	    {
	      cache->saved_regs[regnum].set_addr (-offset);
	      if (regnum == PDP11_FP_REGNUM)
		cache->has_frame_pointer = true;
	    }
	  pc += 2;
	  continue;
	}

      if (insn == PDP11_MOV_SP_R5)
	{
	  /* mov sp,r5 -- the frame pointer now points at the saved one.  */
	  pc += 2;
	  continue;
	}

      if (insn == PDP11_ADD_IMM_SP || insn == PDP11_SUB_IMM_SP)
	{
	  /* add $-N,sp or sub $N,sp -- space for locals.  The immediate
	     follows the instruction.  */
	  if (pc + 4 > end)
	    break;
	  int imm = (int) (short) pdp11_read_word (gdbarch, pc + 2);

	  offset += (insn == PDP11_ADD_IMM_SP) ? -imm : imm;
	  pc += 4;
	  continue;
	}

      break;
    }

  if (cache != NULL)
    cache->sp_offset = offset;
  return pc;
}

/* Implement the "skip_prologue" gdbarch method.  */

static CORE_ADDR
pdp11_skip_prologue (struct gdbarch *gdbarch, CORE_ADDR pc)
{
  CORE_ADDR func_addr, func_end;

  /* The line table knows where the body of the function starts, and is
     right where this file's own guesswork might not be.  */
  if (find_pc_partial_function (pc, NULL, &func_addr, &func_end))
    {
      CORE_ADDR post_prologue_pc
	= skip_prologue_using_sal (gdbarch, func_addr);

      if (post_prologue_pc != 0)
	return std::max (pc, post_prologue_pc);

      return pdp11_analyze_prologue (gdbarch, func_addr, func_end, NULL);
    }

  return pc;
}

/* Extract from REGCACHE a return value of type TYPE into VALBUF.

   Values up to two bytes come back in R0.  A four-byte value uses R0 and
   R1, R0 holding the high half -- which is also the order the two words
   are stored in memory in, this machine keeping the high word of a
   32-bit quantity at the lower address.  */

static void
pdp11_extract_return_value (struct type *type, struct regcache *regcache,
			    gdb_byte *valbuf)
{
  struct gdbarch *gdbarch = regcache->arch ();
  enum bfd_endian byte_order = gdbarch_byte_order (gdbarch);
  int len = type->length ();
  ULONGEST regval;

  if (len <= 2)
    {
      regcache_cooked_read_unsigned (regcache, PDP11_R0_REGNUM, &regval);
      store_unsigned_integer (valbuf, len, byte_order, regval);
      return;
    }

  regcache_cooked_read_unsigned (regcache, PDP11_R0_REGNUM, &regval);
  store_unsigned_integer (valbuf, 2, byte_order, regval);
  regcache_cooked_read_unsigned (regcache, PDP11_R1_REGNUM, &regval);
  store_unsigned_integer (valbuf + 2, 2, byte_order, regval);
}

/* Write into REGCACHE a return value of type TYPE taken from VALBUF.  */

static void
pdp11_store_return_value (struct type *type, struct regcache *regcache,
			  const gdb_byte *valbuf)
{
  struct gdbarch *gdbarch = regcache->arch ();
  enum bfd_endian byte_order = gdbarch_byte_order (gdbarch);
  int len = type->length ();

  if (len <= 2)
    {
      regcache_cooked_write_unsigned
	(regcache, PDP11_R0_REGNUM,
	 extract_unsigned_integer (valbuf, len, byte_order));
      return;
    }

  regcache_cooked_write_unsigned
    (regcache, PDP11_R0_REGNUM,
     extract_unsigned_integer (valbuf, 2, byte_order));
  regcache_cooked_write_unsigned
    (regcache, PDP11_R1_REGNUM,
     extract_unsigned_integer (valbuf + 2, 2, byte_order));
}

/* Implement the "return_value" gdbarch method.

   Anything wider than four bytes, and every floating-point value on a
   machine without the FP11 this port does not assume, comes back through
   memory: the caller passes a hidden pointer and the callee writes
   through it.  */

static enum return_value_convention
pdp11_return_value (struct gdbarch *gdbarch, struct value *function,
		    struct type *valtype, struct regcache *regcache,
		    gdb_byte *readbuf, const gdb_byte *writebuf)
{
  enum type_code code = valtype->code ();

  if (valtype->length () > 4
      || code == TYPE_CODE_FLT
      || code == TYPE_CODE_COMPLEX
      || code == TYPE_CODE_ARRAY)
    return RETURN_VALUE_STRUCT_CONVENTION;

  if (readbuf != NULL)
    pdp11_extract_return_value (valtype, regcache, readbuf);
  if (writebuf != NULL)
    pdp11_store_return_value (valtype, regcache, writebuf);
  return RETURN_VALUE_REGISTER_CONVENTION;
}

/* Implement the "frame_align" gdbarch method.  Everything on the stack
   is word-aligned; the hardware traps an odd stack pointer.  */

static CORE_ADDR
pdp11_frame_align (struct gdbarch *gdbarch, CORE_ADDR sp)
{
  return sp & ~(CORE_ADDR) 1;
}

/* Build the frame cache for THIS_FRAME by reading its prologue.  */

static struct pdp11_frame_cache *
pdp11_frame_cache (const frame_info_ptr &this_frame, void **this_cache)
{
  struct pdp11_frame_cache *cache;

  if (*this_cache != NULL)
    return (struct pdp11_frame_cache *) *this_cache;

  cache = FRAME_OBSTACK_ZALLOC (struct pdp11_frame_cache);
  cache->saved_regs = trad_frame_alloc_saved_regs (this_frame);
  *this_cache = cache;

  struct gdbarch *gdbarch = get_frame_arch (this_frame);
  cache->func = get_frame_func (this_frame);

  if (cache->func != 0)
    pdp11_analyze_prologue (gdbarch, cache->func,
			    get_frame_pc (this_frame), cache);

  if (cache->has_frame_pointer)
    {
      /* R5 points at the caller's saved R5, which the prologue pushed
	 just after the call pushed the return address: two words below
	 where the stack pointer stood before the call.  */
      CORE_ADDR fp = get_frame_register_unsigned (this_frame,
						  PDP11_FP_REGNUM);
      cache->cfa = fp + 4;
    }
  else
    {
      CORE_ADDR sp = get_frame_register_unsigned (this_frame,
						  PDP11_SP_REGNUM);
      cache->cfa = sp + cache->sp_offset + 2;
    }

  /* The prologue recorded where it put things relative to the top of the
     frame; now that the frame has an address, make them addresses.  */
  for (int regnum = 0; regnum < PDP11_NUM_REGS; regnum++)
    if (cache->saved_regs[regnum].is_addr ())
      cache->saved_regs[regnum].set_addr (cache->cfa
					  + cache->saved_regs[regnum].addr ());

  /* The call pushed the return address at the word below the CFA.  */
  cache->saved_regs[PDP11_PC_REGNUM].set_addr (cache->cfa - 2);
  cache->saved_regs[PDP11_SP_REGNUM].set_value (cache->cfa);

  return cache;
}

static void
pdp11_frame_this_id (const frame_info_ptr &this_frame, void **this_cache,
		     struct frame_id *this_id)
{
  struct pdp11_frame_cache *cache = pdp11_frame_cache (this_frame,
						       this_cache);

  if (cache->cfa == 0 || cache->func == 0)
    return;  /* The outermost frame.  */

  *this_id = frame_id_build (cache->cfa, cache->func);
}

static struct value *
pdp11_frame_prev_register (const frame_info_ptr &this_frame,
			   void **this_cache, int regnum)
{
  struct pdp11_frame_cache *cache = pdp11_frame_cache (this_frame,
						       this_cache);

  return trad_frame_get_prev_register (this_frame, cache->saved_regs, regnum);
}

static const struct frame_unwind_legacy pdp11_frame_unwind (
  "pdp11 prologue",
  NORMAL_FRAME,
  FRAME_UNWIND_ARCH,
  default_frame_unwind_stop_reason,
  pdp11_frame_this_id,
  pdp11_frame_prev_register,
  NULL,
  default_frame_sniffer
);

static CORE_ADDR
pdp11_frame_base_address (const frame_info_ptr &this_frame, void **this_cache)
{
  struct pdp11_frame_cache *cache = pdp11_frame_cache (this_frame,
						       this_cache);

  return cache->cfa;
}

static const struct frame_base pdp11_frame_base =
{
  &pdp11_frame_unwind,
  pdp11_frame_base_address,
  pdp11_frame_base_address,
  pdp11_frame_base_address
};

/* Implement the "unwind_pc" and "unwind_sp" gdbarch methods.  */

static CORE_ADDR
pdp11_unwind_pc (struct gdbarch *gdbarch, const frame_info_ptr &next_frame)
{
  return frame_unwind_register_unsigned (next_frame, PDP11_PC_REGNUM);
}

static CORE_ADDR
pdp11_unwind_sp (struct gdbarch *gdbarch, const frame_info_ptr &next_frame)
{
  return frame_unwind_register_unsigned (next_frame, PDP11_SP_REGNUM);
}

/* Initialize the current architecture.  */

static struct gdbarch *
pdp11_gdbarch_init (struct gdbarch_info info, struct gdbarch_list *arches)
{
  /* If there is already a candidate, use it.  */
  arches = gdbarch_list_lookup_by_info (arches, &info);
  if (arches != NULL)
    return arches->gdbarch;

  struct gdbarch *gdbarch = gdbarch_alloc (&info, NULL);

  /* Data types.  A word is 16 bits and so is everything the hardware
     addresses with; long is two words and long long four, neither of
     which the machine has an instruction for.  */
  set_gdbarch_short_bit (gdbarch, 16);
  set_gdbarch_int_bit (gdbarch, 16);
  set_gdbarch_long_bit (gdbarch, 32);
  set_gdbarch_long_long_bit (gdbarch, 64);
  set_gdbarch_ptr_bit (gdbarch, 16);
  set_gdbarch_addr_bit (gdbarch, 16);
  set_gdbarch_char_signed (gdbarch, 1);

  /* The DEC floating formats, which are the VAX ones: the machine is
     where VAX inherited them from.  */
  set_gdbarch_float_bit (gdbarch, 32);
  set_gdbarch_float_format (gdbarch, floatformats_vax_f);
  set_gdbarch_double_bit (gdbarch, 64);
  set_gdbarch_double_format (gdbarch, floatformats_vax_d);
  set_gdbarch_long_double_bit (gdbarch, 64);
  set_gdbarch_long_double_format (gdbarch, floatformats_vax_d);

  /* Registers.  */
  set_gdbarch_num_regs (gdbarch, PDP11_NUM_REGS);
  set_gdbarch_register_name (gdbarch, pdp11_register_name);
  set_gdbarch_register_type (gdbarch, pdp11_register_type);
  set_gdbarch_sp_regnum (gdbarch, PDP11_SP_REGNUM);
  set_gdbarch_pc_regnum (gdbarch, PDP11_PC_REGNUM);
  set_gdbarch_ps_regnum (gdbarch, PDP11_PS_REGNUM);

  /* Frames and the stack, which grows down.  */
  set_gdbarch_skip_prologue (gdbarch, pdp11_skip_prologue);
  set_gdbarch_inner_than (gdbarch, core_addr_lessthan);
  set_gdbarch_frame_align (gdbarch, pdp11_frame_align);
  set_gdbarch_unwind_pc (gdbarch, pdp11_unwind_pc);
  set_gdbarch_unwind_sp (gdbarch, pdp11_unwind_sp);

  set_gdbarch_return_value (gdbarch, pdp11_return_value);

  set_gdbarch_breakpoint_kind_from_pc (gdbarch,
				       pdp11_breakpoint::kind_from_pc);
  set_gdbarch_sw_breakpoint_from_kind (gdbarch,
				       pdp11_breakpoint::bp_from_kind);

  frame_base_set_default (gdbarch, &pdp11_frame_base);

  /* Hook in ABI-specific overrides, if they have been registered.  */
  gdbarch_init_osabi (info, gdbarch);

  /* Call frame information first: where a function has it, it is exact,
     and the prologue reader below is only for what does not.  */
  dwarf2_append_unwinders (gdbarch);
  frame_unwind_append_unwinder (gdbarch, &pdp11_frame_unwind);

  return gdbarch;
}

INIT_GDB_FILE (pdp11_tdep)
{
  gdbarch_register (bfd_arch_pdp11, pdp11_gdbarch_init);
}
