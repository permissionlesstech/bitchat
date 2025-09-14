/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file resolve.h
 * \brief Header for resolve.c
 **/

#ifndef TOR_RESOLVE_H
#define TOR_RESOLVE_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"
#ifdef _WIN32
#include <winsock2.h>
#endif

#if defined(HAVE_SECCOMP_H) && defined(__linux__)
#define USE_SANDBOX_GETADDRINFO
#endif

struct tor_addr_t;

/*
 * Primary lookup functions.
 */
MOCK_DECL(int, tor_lookup_hostname,(const char *name, uint32_t *addr));
MOCK_DECL(int, tor_addr_lookup,(const char *name, uint16_t family,
                                struct tor_addr_t *addr_out));
int tor_addr_port_lookup(const char *s, struct tor_addr_t *addr_out,
                         uint16_t *port_out);

/*
 * Sandbox helpers
 */
struct addrinfo;
#ifdef USE_SANDBOX_GETADDRINFO
/** Pre-calls getaddrinfo in order to pre-record result. */
int tor_add_addrinfo(const char *addr);

struct addrinfo;
/** Replacement for getaddrinfo(), using pre-recorded results. */
int tor_getaddrinfo(const char *name, const char *servname,
                        const struct addrinfo *hints,
                        struct addrinfo **res);
void tor_freeaddrinfo(struct addrinfo *addrinfo);
void tor_free_getaddrinfo_cache(void);
#else /* !defined(USE_SANDBOX_GETADDRINFO) */
#define tor_getaddrinfo(name, servname, hints, res)  \
  getaddrinfo((name),(servname), (hints),(res))
#define tor_add_addrinfo(name) \
  ((void)(name))
#define tor_freeaddrinfo(addrinfo) \
  freeaddrinfo((addrinfo))
#define tor_free_getaddrinfo_cache()
#endif /* defined(USE_SANDBOX_GETADDRINFO) */

void sandbox_disable_getaddrinfo_cache(void);
void tor_make_getaddrinfo_cache_active(void);

/*
 * Internal resolver wrapper; exposed for mocking.
 */
#ifdef RESOLVE_PRIVATE
MOCK_DECL(STATIC int, tor_addr_lookup_host_impl, (const char *name,
                                                  uint16_t family,
                                                  struct tor_addr_t *addr));
#endif

#endif /* !defined(TOR_RESOLVE_H) */
