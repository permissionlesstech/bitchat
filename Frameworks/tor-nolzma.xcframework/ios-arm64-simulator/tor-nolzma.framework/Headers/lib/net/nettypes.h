/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file nettypes.h
 * \brief Declarations for types used throughout the Tor networking system
 **/

#ifndef TOR_NET_TYPES_H
#define TOR_NET_TYPES_H

#include "orconfig.h"
#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif
#ifdef HAVE_SYS_SOCKET_H
#include <sys/socket.h>
#endif

#if (SIZEOF_SOCKLEN_T == 0)
typedef int socklen_t;
#endif

#ifdef _WIN32
/* XXX Actually, this should arguably be SOCKET; we use intptr_t here so that
 * any inadvertent checks for the socket being <= 0 or > 0 will probably
 * still work. */
#define tor_socket_t intptr_t
#define TOR_SOCKET_T_FORMAT "%"PRIuPTR
#define SOCKET_OK(s) ((SOCKET)(s) != INVALID_SOCKET)
#define TOR_INVALID_SOCKET INVALID_SOCKET
#else /* !defined(_WIN32) */
/** Type used for a network socket. */
#define tor_socket_t int
#define TOR_SOCKET_T_FORMAT "%d"
/** Macro: true iff 's' is a possible value for a valid initialized socket. */
#define SOCKET_OK(s) ((s) >= 0)
/** Error/uninitialized value for a tor_socket_t. */
#define TOR_INVALID_SOCKET (-1)
#endif /* defined(_WIN32) */

#endif /* !defined(TOR_NET_TYPES_H) */
