/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_SOCKETPAIR_H
#define TOR_SOCKETPAIR_H

/**
 * @file socketpair.h
 * @brief Header for socketpair.c
 **/

#include "orconfig.h"
#include "lib/testsupport/testsupport.h"
#include "lib/net/nettypes.h"

#if !defined(HAVE_SOCKETPAIR) || defined(_WIN32) || defined(TOR_UNIT_TESTS)
#define NEED_ERSATZ_SOCKETPAIR
int tor_ersatz_socketpair(int family, int type, int protocol,
                          tor_socket_t fd[2]);
#endif

#endif /* !defined(TOR_SOCKETPAIR_H) */
