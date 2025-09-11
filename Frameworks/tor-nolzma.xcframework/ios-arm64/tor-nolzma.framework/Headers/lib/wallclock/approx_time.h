/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file approx_time.h
 * \brief Header for approx_time.c
 **/

#ifndef TOR_APPROX_TIME_H
#define TOR_APPROX_TIME_H

#include <time.h>

/* Cached time */
#ifdef TIME_IS_FAST
#define approx_time() time(NULL)
#define update_approx_time(t) STMT_NIL
#else
time_t approx_time(void);
void update_approx_time(time_t now);
#endif /* defined(TIME_IS_FAST) */

#endif /* !defined(TOR_APPROX_TIME_H) */
