/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file addsub.h
 *
 * \brief Header for addsub.c
 **/

#ifndef TOR_INTMATH_ADDSUB_H
#define TOR_INTMATH_ADDSUB_H

#include "lib/cc/torint.h"

uint32_t tor_add_u32_nowrap(uint32_t a, uint32_t b);

#endif /* !defined(TOR_INTMATH_ADDSUB_H) */
