/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef COMPILER_H
#define COMPILER_H

#include <stdint.h>
#include <stdbool.h>
#include <hashx.h>
#include "virtual_memory.h"
#include "program.h"

HASHX_PRIVATE bool hashx_compile_x86(const hashx_program* program, uint8_t* code);

HASHX_PRIVATE bool hashx_compile_a64(const hashx_program* program, uint8_t* code);

#if defined(_M_X64) || defined(__x86_64__)
#define HASHX_COMPILER_X86
#define hashx_compile(p,c) hashx_compile_x86(p,c)
#elif defined(__aarch64__)
#define HASHX_COMPILER_A64
#define hashx_compile(p,c) hashx_compile_a64(p,c)
#else
#define hashx_compile(p,c) (false)
#endif

HASHX_PRIVATE void hashx_compiler_init(hashx_ctx* compiler);
HASHX_PRIVATE void hashx_compiler_destroy(hashx_ctx* compiler);

/* Compiled code sizes in bytes:
 *
 *      Prologue   Epilogue   MulH   Reg-Reg   Reg-Imm32   Branch+Tgt   MaxInst
 * X86  69         64         9      3..4      7           15           10 (br)
 * A64  40         36         4      4         12          24           24 (br)
 *
 * Maximum code sizes, assuming an arbitrary instruction mix including unlimited
 * branch instructions. (Branch size * 512 + prologue + epilogue)
 *
 *      Max possible code size (any instructions)
 * X86  5253
 * A64  12364
 *
 * Actual code sizes tend to be much smaller due to the instruction mix chosen
 * by the program generator. To get a quick overview of the statistics, we
 * measure the sample mean and sample standard deviation for 1 million random
 * hash programs:
 *
 *      Mean     Std Deviation   4096 bytes at
 * X86  2786.4   26.259          49.9 standard deviations
 * A64  3507.7   58.526          10.1 standard deviations
 *
 * If we search for PRNG sequences that maximize generated code size, it's easy
 * to find aarch64 code that needs in the range of 4100-4300 bytes. On x86, this
 * search still doesn't turn up programs anywhere close to a full page.
 *
 * Anyway, this is all to say that a one-page buffer is fine except for in
 * extremely rare cases on aarch64, and a two-page buffer is enough for any
 * behavior we can expect from the program generator under arbitrary input,
 * but only a 4-page buffer is enough for fully arbitrary instruction streams
 * on any architecture.
 *
 * Let's use a 2-page buffer on aarch64, or 1-page elsewhere.
 *
 * Note that the buffer allocation is done by platform-independent code,
 * so COMP_CODE_SIZE must always have a valid size even on platforms where
 * it is not actually supported or used.
 *
 * If this buffer fills up, compilation will fail with a runtime error.
 */

#ifdef HASHX_COMPILER_A64
#define COMP_CODE_SIZE (4096 * 2)
#else
#define COMP_CODE_SIZE (4096 * 1)
#endif

#endif
