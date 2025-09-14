/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file extendinfo.h
 * @brief Header for core/or/extendinfo.c
 **/

#ifndef TOR_CORE_OR_EXTENDINFO_H
#define TOR_CORE_OR_EXTENDINFO_H

extend_info_t *extend_info_new(const char *nickname,
                               const char *rsa_id_digest,
                               const struct ed25519_public_key_t *ed_id,
                               crypto_pk_t *onion_key,
                               const struct curve25519_public_key_t *ntor_key,
                               const tor_addr_t *addr, uint16_t port,
                               const struct protover_summary_flags_t *pv,
                               bool for_exit_use);
extend_info_t *extend_info_from_node(const node_t *r, int for_direct_connect,
                                     bool for_exit);
extend_info_t *extend_info_dup(extend_info_t *info);
void extend_info_free_(extend_info_t *info);
#define extend_info_free(info) \
  FREE_AND_NULL(extend_info_t, extend_info_free_, (info))
int extend_info_addr_is_allowed(const tor_addr_t *addr);
int extend_info_supports_tap(const extend_info_t* ei);
int extend_info_supports_ntor(const extend_info_t* ei);
int extend_info_supports_ntor_v3(const extend_info_t *ei);
int extend_info_has_preferred_onion_key(const extend_info_t* ei);
bool extend_info_has_orport(const extend_info_t *ei,
                            const tor_addr_t *addr, uint16_t port);
int extend_info_add_orport(extend_info_t *ei,
                           const tor_addr_t *addr,
                           uint16_t port);
const tor_addr_port_t *extend_info_get_orport(const extend_info_t *ei,
                                              int family);
const tor_addr_port_t *extend_info_pick_orport(const extend_info_t *ei);
bool extend_info_any_orport_addr_is_internal(const extend_info_t *ei);

#endif /* !defined(TOR_CORE_OR_EXTENDINFO_H) */
