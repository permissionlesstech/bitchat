/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file time_to_tm.h
 * \brief Header for time_to_tm.c
 **/

#ifndef TOR_WALLCLOCK_TIME_TO_TM_H
#define TOR_WALLCLOCK_TIME_TO_TM_H

#include <sys/types.h>

struct tm;
struct tm *tor_localtime_r_msg(const time_t *timep, struct tm *result,
                               char **err_out);
struct tm *tor_gmtime_r_msg(const time_t *timep, struct tm *result,
                            char **err_out);

#endif /* !defined(TOR_WALLCLOCK_TIME_TO_TM_H) */
