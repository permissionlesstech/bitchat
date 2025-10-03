/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file tor_gettimeofday.h
 * \brief Header for tor_gettimeofday.c
 **/

#ifndef TOR_GETTIMEOFDAY_H
#define TOR_GETTIMEOFDAY_H

#include "lib/testsupport/testsupport.h"

struct timeval;

MOCK_DECL(void, tor_gettimeofday, (struct timeval *timeval));

#endif /* !defined(TOR_GETTIMEOFDAY_H) */
