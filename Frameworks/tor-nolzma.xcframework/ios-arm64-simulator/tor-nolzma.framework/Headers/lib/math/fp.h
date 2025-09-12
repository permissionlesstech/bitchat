/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file fp.h
 *
 * \brief Header for fp.c
 **/

#ifndef TOR_FP_H
#define TOR_FP_H

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"

double tor_mathlog(double d) ATTR_CONST;
long tor_lround(double d) ATTR_CONST;
int64_t tor_llround(double d) ATTR_CONST;
int64_t clamp_double_to_int64(double number);
int tor_isinf(double x);

#endif /* !defined(TOR_FP_H) */
