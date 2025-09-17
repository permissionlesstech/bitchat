/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_util.h
 *
 * \brief Common functions for cryptographic routines.
 **/

#ifndef TOR_CRYPTO_UTIL_H
#define TOR_CRYPTO_UTIL_H

#include "lib/cc/torint.h"
#include "lib/malloc/malloc.h"

/** OpenSSL-based utility functions. */
void memwipe(void *mem, uint8_t byte, size_t sz);

void tor_str_wipe_and_free_(char *str);
/**
 * Securely all memory in <b>str</b>, then free it.
 *
 * As tor_free(), tolerates null pointers, and sets <b>str</b> to NULL.
 **/
#define tor_str_wipe_and_free(str)                      \
  FREE_AND_NULL(char, tor_str_wipe_and_free_, (str))

#endif /* !defined(TOR_CRYPTO_UTIL_H) */
