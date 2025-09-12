/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_BITARRAY_H
#define TOR_BITARRAY_H

/**
 * \file bitarray.h
 *
 * \brief Implements a variable-sized (but non-resizeable) bit-array.
 **/

#include "orconfig.h"
#include <string.h>
#include "lib/cc/torint.h"
#include "lib/malloc/malloc.h"

#if SIZEOF_INT == 4
#define BITARRAY_SHIFT 5
#elif SIZEOF_INT == 8
#define BITARRAY_SHIFT 6
#else
#error "int is neither 4 nor 8 bytes. I can't deal with that."
#endif /* SIZEOF_INT == 4 || ... */
#define BITARRAY_MASK ((1u<<BITARRAY_SHIFT)-1)

/** A random-access array of one-bit-wide elements. */
typedef unsigned int bitarray_t;
/** Create a new bit array that can hold <b>n_bits</b> bits. */
static inline bitarray_t *
bitarray_init_zero(unsigned int n_bits)
{
  /* round up to the next int. */
  size_t sz = (n_bits+BITARRAY_MASK) >> BITARRAY_SHIFT;
  return tor_calloc(sz, sizeof(unsigned int));
}
/** Expand <b>ba</b> from holding <b>n_bits_old</b> to <b>n_bits_new</b>,
 * clearing all new bits.  Returns a possibly changed pointer to the
 * bitarray. */
static inline bitarray_t *
bitarray_expand(bitarray_t *ba,
                unsigned int n_bits_old, unsigned int n_bits_new)
{
  size_t sz_old = (n_bits_old+BITARRAY_MASK) >> BITARRAY_SHIFT;
  size_t sz_new = (n_bits_new+BITARRAY_MASK) >> BITARRAY_SHIFT;
  char *ptr;
  if (sz_new <= sz_old)
    return ba;
  ptr = tor_reallocarray(ba, sz_new, sizeof(unsigned int));
  /* This memset does nothing to the older excess bytes.  But they were
   * already set to 0 by bitarry_init_zero. */
  memset(ptr+sz_old*sizeof(unsigned int), 0,
         (sz_new-sz_old)*sizeof(unsigned int));
  return (bitarray_t*) ptr;
}
/** Free the bit array <b>ba</b>. */
static inline void
bitarray_free_(bitarray_t *ba)
{
  tor_free(ba);
}
#define bitarray_free(ba) FREE_AND_NULL(bitarray_t, bitarray_free_, (ba))

/** Set the <b>bit</b>th bit in <b>b</b> to 1. */
static inline void
bitarray_set(bitarray_t *b, int bit)
{
  b[bit >> BITARRAY_SHIFT] |= (1u << (bit & BITARRAY_MASK));
}
/** Set the <b>bit</b>th bit in <b>b</b> to 0. */
static inline void
bitarray_clear(bitarray_t *b, int bit)
{
  b[bit >> BITARRAY_SHIFT] &= ~ (1u << (bit & BITARRAY_MASK));
}
/** Return true iff <b>bit</b>th bit in <b>b</b> is nonzero.  NOTE: does
 * not necessarily return 1 on true. */
static inline unsigned int
bitarray_is_set(bitarray_t *b, int bit)
{
  return b[bit >> BITARRAY_SHIFT] & (1u << (bit & BITARRAY_MASK));
}

#endif /* !defined(TOR_BITARRAY_H) */
