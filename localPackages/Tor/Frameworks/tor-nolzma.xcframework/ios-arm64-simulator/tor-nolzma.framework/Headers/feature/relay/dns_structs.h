/* Copyright (c) 2003-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dns_structs.h
 *
 * \brief Structures used in dns.c. Exposed to dns.c, and to the unit tests
 * that declare DNS_PRIVATE.
 */

#ifndef TOR_DNS_STRUCTS_H
#define TOR_DNS_STRUCTS_H

#include "ext/ht.h"

/** Longest hostname we're willing to resolve. */
#define MAX_ADDRESSLEN 256

/** Linked list of connections waiting for a DNS answer. */
typedef struct pending_connection_t {
  edge_connection_t *conn;
  struct pending_connection_t *next;
} pending_connection_t;

/** Value of 'magic' field for cached_resolve_t.  Used to try to catch bad
 * pointers and memory stomping. */
#define CACHED_RESOLVE_MAGIC 0x1234F00D

/* Possible states for a cached resolve_t */
/** We are waiting for the resolver system to tell us an answer here.
 * When we get one, or when we time out, the state of this cached_resolve_t
 * will become "DONE" and we'll possibly add a CACHED
 * entry. This cached_resolve_t will be in the hash table so that we will
 * know not to launch more requests for this addr, but rather to add more
 * connections to the pending list for the addr. */
#define CACHE_STATE_PENDING 0
/** This used to be a pending cached_resolve_t, and we got an answer for it.
 * Now we're waiting for this cached_resolve_t to expire.  This should
 * have no pending connections, and should not appear in the hash table. */
#define CACHE_STATE_DONE 1
/** We are caching an answer for this address. This should have no pending
 * connections, and should appear in the hash table. */
#define CACHE_STATE_CACHED 2

/** @name status values for a single DNS request.
 *
 * @{ */
/** The DNS request is in progress. */
#define RES_STATUS_INFLIGHT 1
/** The DNS request finished and gave an answer */
#define RES_STATUS_DONE_OK 2
/** The DNS request finished and gave an error */
#define RES_STATUS_DONE_ERR 3
/**@}*/

/** A DNS request: possibly completed, possibly pending; cached_resolve
 * structs are stored at the OR side in a hash table, and as a linked
 * list from oldest to newest.
 */
typedef struct cached_resolve_t {
  HT_ENTRY(cached_resolve_t) node;
  uint32_t magic;  /**< Must be CACHED_RESOLVE_MAGIC */
  char address[MAX_ADDRESSLEN]; /**< The hostname to be resolved. */

  union {
    uint32_t addr_ipv4; /**< IPv4 addr for <b>address</b>, if successful.
                         * (In host order.) */
    int err_ipv4; /**< One of DNS_ERR_*, if IPv4 lookup failed. */
  } result_ipv4; /**< Outcome of IPv4 lookup */
  union {
    struct in6_addr addr_ipv6; /**< IPv6 addr for <b>address</b>, if
                                * successful */
    int err_ipv6; /**< One of DNS_ERR_*, if IPv6 lookup failed. */
  } result_ipv6; /**< Outcome of IPv6 lookup, if any */
  union {
    char *hostname; /** A hostname, if PTR lookup happened successfully*/
    int err_hostname; /** One of DNS_ERR_*, if PTR lookup failed. */
  } result_ptr;
  /** @name Status fields
   *
   * These take one of the RES_STATUS_* values, depending on the state
   * of the corresponding lookup.
   *
   * @{ */
  unsigned int res_status_ipv4 : 2;
  unsigned int res_status_ipv6 : 2;
  unsigned int res_status_hostname : 2;
  /**@}*/
  uint8_t state; /**< Is this cached entry pending/done/informative? */

  time_t expire; /**< Remove items from cache after this time. */
  uint32_t ttl_ipv4; /**< What TTL did the nameserver tell us? */
  uint32_t ttl_ipv6; /**< What TTL did the nameserver tell us? */
  uint32_t ttl_hostname; /**< What TTL did the nameserver tell us? */
  /** Connections that want to know when we get an answer for this resolve. */
  pending_connection_t *pending_connections;
  /** Position of this element in the heap*/
  int minheap_idx;
} cached_resolve_t;

#endif /* !defined(TOR_DNS_STRUCTS_H) */
