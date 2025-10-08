/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file muldiv.h
 *
 * \brief Header for muldiv.c
 **/

#ifndef TOR_INTMATH_MULDIV_H
#define TOR_INTMATH_MULDIV_H

#include "lib/cc/torint.h"

unsigned round_to_next_multiple_of(unsigned number, unsigned divisor);
uint32_t round_uint32_to_next_multiple_of(uint32_t number, uint32_t divisor);
uint64_t round_uint64_to_next_multiple_of(uint64_t number, uint64_t divisor);

uint64_t tor_mul_u64_nowrap(uint64_t a, uint64_t b);

void simplify_fraction64(uint64_t *numer, uint64_t *denom);

/* Compute the CEIL of <b>a</b> divided by <b>b</b>, for nonnegative <b>a</b>
 * and positive <b>b</b>.  Works on integer types only. Not defined if a+(b-1)
 * can overflow. */
#define CEIL_DIV(a,b) (((a)+((b)-1))/(b))

#endif /* !defined(TOR_INTMATH_MULDIV_H) */
