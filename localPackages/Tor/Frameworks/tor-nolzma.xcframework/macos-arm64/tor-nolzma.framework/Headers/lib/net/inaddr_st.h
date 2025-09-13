/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file inaddr_st.h
 *
 * \brief Define in6_addr, its members, and related types on platforms that
 *    lack it.
 **/

#ifndef TOR_INADDR_ST_H
#define TOR_INADDR_ST_H

#include "orconfig.h"
#include <stddef.h>

#ifdef HAVE_ARPA_INET_H
#include <arpa/inet.h>
#endif
#ifdef HAVE_NETINET_IN_H
#include <netinet/in.h>
#endif
#ifdef HAVE_NETINET_IN6_H
#include <netinet/in6.h>
#endif
#ifdef HAVE_SYS_SOCKET_H
#include <sys/socket.h>
#endif
#ifdef HAVE_SYS_PARAM_H
#include <sys/param.h>
#endif

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#endif

#include "lib/cc/torint.h"

struct in_addr;

/** Implementation of struct in6_addr for platforms that do not have it.
 * Generally, these platforms are ones without IPv6 support, but we want to
 * have a working in6_addr there anyway, so we can use it to parse IPv6
 * addresses. */
#if !defined(HAVE_STRUCT_IN6_ADDR)
struct in6_addr
{
  union {
    uint8_t u6_addr8[16];
    uint16_t u6_addr16[8];
    uint32_t u6_addr32[4];
  } in6_u;
#define s6_addr   in6_u.u6_addr8
#define s6_addr16 in6_u.u6_addr16
#define s6_addr32 in6_u.u6_addr32
};
#endif /* !defined(HAVE_STRUCT_IN6_ADDR) */

/** @{ */
/** Many BSD variants seem not to define these. */
#if defined(__APPLE__) || defined(__darwin__) || \
  defined(__FreeBSD__) || defined(__NetBSD__) || defined(OpenBSD)
#ifndef s6_addr16
#define s6_addr16 __u6_addr.__u6_addr16
#endif
#ifndef s6_addr32
#define s6_addr32 __u6_addr.__u6_addr32
#endif
#endif /* defined(__APPLE__) || defined(__darwin__) || ... */
/** @} */

#ifndef HAVE_SA_FAMILY_T
typedef uint16_t sa_family_t;
#endif

/** @{ */
/** Apparently, MS and Solaris don't define s6_addr16 or s6_addr32; these
 * macros get you a pointer to s6_addr32 or local equivalent. */
#ifdef HAVE_STRUCT_IN6_ADDR_S6_ADDR32
#define S6_ADDR32(x) ((uint32_t*)(x).s6_addr32)
#else
#define S6_ADDR32(x) ((uint32_t*)((char*)&(x).s6_addr))
#endif
#ifdef HAVE_STRUCT_IN6_ADDR_S6_ADDR16
#define S6_ADDR16(x) ((uint16_t*)(x).s6_addr16)
#else
#define S6_ADDR16(x) ((uint16_t*)((char*)&(x).s6_addr))
#endif
/** @} */

/** Implementation of struct sockaddr_in6 on platforms that do not have
 * it. See notes on struct in6_addr. */
#if !defined(HAVE_STRUCT_SOCKADDR_IN6)
struct sockaddr_in6 {
  sa_family_t sin6_family;
  uint16_t sin6_port;
  // uint32_t sin6_flowinfo;
  struct in6_addr sin6_addr;
  // uint32_t sin6_scope_id;
};
#endif /* !defined(HAVE_STRUCT_SOCKADDR_IN6) */

#endif /* !defined(TOR_INADDR_ST_H) */
