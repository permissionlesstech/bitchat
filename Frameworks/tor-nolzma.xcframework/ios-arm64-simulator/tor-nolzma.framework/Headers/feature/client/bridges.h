/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file bridges.h
 * \brief Header file for circuitbuild.c.
 **/

#ifndef TOR_BRIDGES_H
#define TOR_BRIDGES_H

struct bridge_line_t;
struct ed25519_public_key_t;

/* Opaque handle to a configured bridge */
typedef struct bridge_info_t bridge_info_t;

void mark_bridge_list(void);
void sweep_bridge_list(void);
const smartlist_t *bridge_list_get(void);
const uint8_t *bridge_get_rsa_id_digest(const bridge_info_t *bridge);
const tor_addr_port_t * bridge_get_addr_port(const bridge_info_t *bridge);
const char *bridget_get_transport_name(const bridge_info_t *bridge);
bool bridge_has_invalid_transport(const bridge_info_t *bridge);
bridge_info_t *get_configured_bridge_by_addr_port_digest(
                                          const tor_addr_t *addr,
                                          uint16_t port,
                                          const char *digest);
bridge_info_t *get_configured_bridge_by_exact_addr_port_digest(
                                          const tor_addr_t *addr,
                                          uint16_t port,
                                          const char *digest);

int addr_is_a_configured_bridge(const tor_addr_t *addr, uint16_t port,
                                const char *digest);
int extend_info_is_a_configured_bridge(const extend_info_t *ei);
int routerinfo_is_a_configured_bridge(const routerinfo_t *ri);
int node_is_a_configured_bridge(const node_t *node);
void learned_router_identity(const tor_addr_t *addr, uint16_t port,
                             const char *digest,
                             const struct ed25519_public_key_t *ed_id);

void bridge_add_from_config(struct bridge_line_t *bridge_line);
void retry_bridge_descriptor_fetch_directly(const char *digest);
void fetch_bridge_descriptors(const or_options_t *options, time_t now);
void learned_bridge_descriptor(routerinfo_t *ri,
                               int from_cache, int desc_is_new);
const smartlist_t *get_socks_args_by_bridge_addrport(const tor_addr_t *addr,
                                                     uint16_t port);

int any_bridges_dont_support_microdescriptors(void);

const char *find_transport_name_by_bridge_addrport(const tor_addr_t *addr,
                                                   uint16_t port);
struct transport_t;
int get_transport_by_bridge_addrport(const tor_addr_t *addr, uint16_t port,
                                      const struct transport_t **transport);

MOCK_DECL(int, transport_is_needed, (const char *transport_name));
int validate_pluggable_transports_config(void);

MOCK_DECL(smartlist_t *, list_bridge_identities, (void));
MOCK_DECL(download_status_t *, get_bridge_dl_status_by_id,
          (const char *digest));

void bridges_free_all(void);
bool conflux_can_exclude_used_bridges(void);

#ifdef TOR_BRIDGES_PRIVATE
STATIC void clear_bridge_list(void);
STATIC bridge_info_t *find_bridge_by_digest(const char *digest);
STATIC bridge_info_t *get_configured_bridge_by_orports_digest(
                                                  const char *digest,
                                                  const smartlist_t *orports);
STATIC void bridge_resolve_conflicts(const tor_addr_t *addr,
                                     uint16_t port,
                                     const char *digest,
                                     const char *transport_name);
#endif /* defined(TOR_BRIDGES_PRIVATE) */

#endif /* !defined(TOR_BRIDGES_H) */
