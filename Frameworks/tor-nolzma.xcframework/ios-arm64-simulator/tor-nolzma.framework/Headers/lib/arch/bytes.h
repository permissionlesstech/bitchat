/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_BYTES_H
#define TOR_BYTES_H

/**
 * \file bytes.h
 *
 * \brief Inline functions for reading and writing multibyte values from
 *  the middle of strings, and for manipulating byte order.
 **/

#include <string.h>
#include "lib/cc/torint.h"

/**
 * Read an 8-bit from <b>cp</b>.
 */
static inline uint8_t
get_uint8(const void *cp)
{
  return *(const uint8_t*)(cp);
}
/**
 * Store an 8-bit value from <b>v</b> to <b>cp</b>.
 */
static inline void
set_uint8(void *cp, uint8_t v)
{
  *(uint8_t*)cp = v;
}

/**
 * Read a 16-bit value beginning at <b>cp</b>.  Equivalent to
 * *(uint16_t*)(cp), but will not cause segfaults on platforms that forbid
 * unaligned memory access.
 */
static inline uint16_t
get_uint16(const void *cp)
{
  uint16_t v;
  memcpy(&v,cp,2);
  return v;
}
/**
 * Read a 32-bit value beginning at <b>cp</b>.  Equivalent to
 * *(uint32_t*)(cp), but will not cause segfaults on platforms that forbid
 * unaligned memory access.
 */
static inline uint32_t
get_uint32(const void *cp)
{
  uint32_t v;
  memcpy(&v,cp,4);
  return v;
}
/**
 * Read a 64-bit value beginning at <b>cp</b>.  Equivalent to
 * *(uint64_t*)(cp), but will not cause segfaults on platforms that forbid
 * unaligned memory access.
 */
static inline uint64_t
get_uint64(const void *cp)
{
  uint64_t v;
  memcpy(&v,cp,8);
  return v;
}

/**
 * Set a 16-bit value beginning at <b>cp</b> to <b>v</b>. Equivalent to
 * *(uint16_t*)(cp) = v, but will not cause segfaults on platforms that forbid
 * unaligned memory access. */
static inline void
set_uint16(void *cp, uint16_t v)
{
  memcpy(cp,&v,2);
}
/**
 * Set a 32-bit value beginning at <b>cp</b> to <b>v</b>. Equivalent to
 * *(uint32_t*)(cp) = v, but will not cause segfaults on platforms that forbid
 * unaligned memory access. */
static inline void
set_uint32(void *cp, uint32_t v)
{
  memcpy(cp,&v,4);
}
/**
 * Set a 64-bit value beginning at <b>cp</b> to <b>v</b>. Equivalent to
 * *(uint64_t*)(cp) = v, but will not cause segfaults on platforms that forbid
 * unaligned memory access. */
static inline void
set_uint64(void *cp, uint64_t v)
{
  memcpy(cp,&v,8);
}

#if defined(WORDS_BIGENDIAN)
static inline uint16_t
tor_htons(uint32_t a)
{
  return a;
}

static inline uint16_t
tor_ntohs(uint64_t a)
{
  return a;
}

static inline uint32_t
tor_htonl(uint32_t a)
{
  return a;
}

static inline uint32_t
tor_ntohl(uint64_t a)
{
  return a;
}

static inline uint64_t
tor_htonll(uint64_t a)
{
  return a;
}

static inline uint64_t
tor_ntohll(uint64_t a)
{
  return a;
}
#else /* !defined(WORDS_BIGENDIAN) */
/**
 * Convert a 16-bit value from host order to network order (big-endian).
 **/
static inline uint16_t
tor_htons(uint16_t a)
{
  /* Our compilers will indeed recognize this as bswap. */
  return
    ((a & 0x00ff) << 8) |
    ((a & 0xff00) >> 8);
}

/**
 * Convert a 16-bit value from network order (big-endian) to host order.
 **/
static inline uint16_t
tor_ntohs(uint16_t a)
{
  return tor_htons(a);
}

/**
 * Convert a 32-bit value from host order to network order (big-endian).
 **/
static inline uint32_t
tor_htonl(uint32_t a)
{
  /* Our compilers will indeed recognize this as bswap. */
  return
    ((a & 0x000000ff) <<24) |
    ((a & 0x0000ff00) << 8) |
    ((a & 0x00ff0000) >> 8) |
    ((a & 0xff000000) >>24);
}

/**
 * Convert a 32-bit value from network order (big-endian) to host order.
 **/
static inline uint32_t
tor_ntohl(uint32_t a)
{
  return tor_htonl(a);
}

/** Return a uint64_t value from <b>a</b> in network byte order. */
static inline uint64_t
tor_htonll(uint64_t a)
{
  /* Little endian. The worst... */
  return tor_htonl((uint32_t)(a>>32)) |
    (((uint64_t)tor_htonl((uint32_t)a))<<32);
}

/** Return a uint64_t value from <b>a</b> in host byte order. */
static inline uint64_t
tor_ntohll(uint64_t a)
{
  return tor_htonll(a);
}
#endif /* defined(WORDS_BIGENDIAN) */

#endif /* !defined(TOR_BYTES_H) */
