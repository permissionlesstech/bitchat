/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file inaddr.h
 * \brief Header for inaddr.c.
 **/

#ifndef TOR_INADDR_H
#define TOR_INADDR_H

#include "orconfig.h"
#include <stddef.h>

struct in_addr;

int tor_inet_aton(const char *str, struct in_addr *addr);
/** Length of a buffer to allocate to hold the results of tor_inet_ntoa.*/
#define INET_NTOA_BUF_LEN 16
int tor_inet_ntoa(const struct in_addr *in, char *buf, size_t buf_len);

const char *tor_inet_ntop(int af, const void *src, char *dst, size_t len);
int tor_inet_pton(int af, const char *src, void *dst);

#endif /* !defined(TOR_INADDR_H) */
