/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file tvdiff.h
 * \brief Header for tvdiff.c
 **/

#ifndef TOR_TVDIFF_H
#define TOR_TVDIFF_H

#include "lib/cc/torint.h"
struct timeval;

long tv_udiff(const struct timeval *start, const struct timeval *end);
long tv_mdiff(const struct timeval *start, const struct timeval *end);
int64_t tv_to_msec(const struct timeval *tv);

time_t time_diff(const time_t from, const time_t to);

#endif /* !defined(TOR_TVDIFF_H) */
