/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file scanf.h
 * \brief Header for scanf.c
 **/

#ifndef TOR_UTIL_SCANF_H
#define TOR_UTIL_SCANF_H

#include "orconfig.h"
#include "lib/cc/compat_compiler.h"

#include <stdarg.h>

int tor_vsscanf(const char *buf, const char *pattern, va_list ap) \
  CHECK_SCANF(2, 0);
int tor_sscanf(const char *buf, const char *pattern, ...)
  CHECK_SCANF(2, 3);

#endif /* !defined(TOR_UTIL_SCANF_H) */
