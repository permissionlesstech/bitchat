/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file bits.h
 *
 * \brief Header for bits.c
 **/

#ifndef TOR_INTMATH_BITS_H
#define TOR_INTMATH_BITS_H

#include "lib/cc/torint.h"
#include "lib/cc/compat_compiler.h"

int tor_log2(uint64_t u64) ATTR_CONST;
uint64_t round_to_power_of_2(uint64_t u64);
int n_bits_set_u8(uint8_t v);

#endif /* !defined(TOR_INTMATH_BITS_H) */
