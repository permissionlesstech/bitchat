/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file meminfo.h
 *
 * \brief Header for meminfo.c
 **/

#ifndef TOR_MEMINFO_H
#define TOR_MEMINFO_H

#include "lib/testsupport/testsupport.h"
#include <stddef.h>

MOCK_DECL(int, get_total_system_memory, (size_t *mem_out));

#endif /* !defined(TOR_MEMINFO_H) */
