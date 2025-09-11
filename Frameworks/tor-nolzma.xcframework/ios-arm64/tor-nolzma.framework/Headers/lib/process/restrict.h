/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file restrict.h
 * \brief Header for restrict.c
 **/

#ifndef TOR_RESTRICT_H
#define TOR_RESTRICT_H

#include "orconfig.h"
#ifdef HAVE_SYS_RESOURCE_H
#include <sys/resource.h>
#endif

int tor_disable_debugger_attach(void);
int tor_mlockall(void);

#if !defined(HAVE_RLIM_T)
typedef unsigned long rlim_t;
#endif
int set_max_file_descriptors(rlim_t limit, int *max_out);

#endif /* !defined(TOR_RESTRICT_H) */
