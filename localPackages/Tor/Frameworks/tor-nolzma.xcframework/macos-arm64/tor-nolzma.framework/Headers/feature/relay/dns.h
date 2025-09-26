/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dns.h
 * \brief Header file for dns.c.
 **/

#ifndef TOR_DNS_H
#define TOR_DNS_H

#ifdef HAVE_MODULE_RELAY

int dns_init(void);
int has_dns_init_failed(void);
int dns_reset(void);
void connection_dns_remove(edge_connection_t *conn);
void assert_connection_edge_not_dns_pending(edge_connection_t *conn);
int dns_resolve(edge_connection_t *exitconn);
int dns_seems_to_be_broken(void);
int dns_seems_to_be_broken_for_ipv6(void);
void dns_reset_correctness_checks(void);
size_t dns_cache_total_allocation(void);
void dump_dns_mem_usage(int severity);
size_t dns_cache_handle_oom(time_t now, size_t min_remove_bytes);
void dns_new_consensus_params(const networkstatus_t *ns);

/* These functions are only used within the feature/relay module, and don't
 * need stubs. */
void dns_free_all(void);
void dns_launch_correctness_checks(void);

#else /* !defined(HAVE_MODULE_RELAY) */

#define dns_init() (0)
#define dns_seems_to_be_broken() (0)
#define has_dns_init_failed() (0)
#define dns_cache_total_allocation() (0)

#define dns_reset_correctness_checks() STMT_NIL

#define assert_connection_edge_not_dns_pending(conn) \
  ((void)(conn))
#define dump_dns_mem_usage(severity)\
  ((void)(severity))
#define dns_cache_handle_oom(now, bytes) \
  ((void)(now), (void)(bytes), 0)
#define dns_new_consensus_params(ns) \
  ((void) ns)

#define connection_dns_remove(conn) \
  STMT_BEGIN                        \
  (void)(conn);                     \
  tor_assert_nonfatal_unreached();  \
  STMT_END

static inline int
dns_reset(void)
{
  return 0;
}
static inline int
dns_resolve(edge_connection_t *exitconn)
{
  (void)exitconn;
  tor_assert_nonfatal_unreached();
  return -1;
}

#endif /* defined(HAVE_MODULE_RELAY) */

#ifdef DNS_PRIVATE
#include "feature/relay/dns_structs.h"

size_t number_of_configured_nameservers(void);
#ifdef HAVE_EVDNS_BASE_GET_NAMESERVER_ADDR
tor_addr_t *configured_nameserver_address(const size_t idx);
#endif

MOCK_DECL(STATIC void,dns_cancel_pending_resolve,(const char *question));
MOCK_DECL(STATIC int,dns_resolve_impl,(edge_connection_t *exitconn,
int is_resolve,or_circuit_t *oncirc, char **hostname_out,
int *made_connection_pending_out, cached_resolve_t **resolve_out));

MOCK_DECL(STATIC void,send_resolved_cell,(edge_connection_t *conn,
uint8_t answer_type,const cached_resolve_t *resolved));

MOCK_DECL(STATIC void,send_resolved_hostname_cell,(edge_connection_t *conn,
const char *hostname));

cached_resolve_t *dns_get_cache_entry(cached_resolve_t *query);
void dns_insert_cache_entry(cached_resolve_t *new_entry);

MOCK_DECL(STATIC int,
set_exitconn_info_from_resolve,(edge_connection_t *exitconn,
                                const cached_resolve_t *resolve,
                                char **hostname_out));

MOCK_DECL(STATIC int,
launch_resolve,(cached_resolve_t *resolve));

#endif /* defined(DNS_PRIVATE) */

#endif /* !defined(TOR_DNS_H) */
