/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file entry_port_cfg_st.h
 * @brief Configuration structure for client ports.
 **/

#ifndef ENTRY_PORT_CFG_ST_H
#define ENTRY_PORT_CFG_ST_H

#include "lib/cc/torint.h"
#include "core/or/or.h"

struct entry_port_cfg_t {
  /* Client port types (socks, dns, trans, natd) only: */
  uint8_t isolation_flags; /**< Zero or more isolation flags */
  int session_group; /**< A session group, or -1 if this port is not in a
                      * session group. */

  /* Socks only: */
  /** When both no-auth and user/pass are advertised by a SOCKS client, select
   * no-auth. */
  unsigned int socks_prefer_no_auth : 1;
  /** When ISO_SOCKSAUTH is in use, Keep-Alive circuits indefinitely. */
  unsigned int socks_iso_keep_alive : 1;

  /* Client port types only: */
  unsigned int ipv4_traffic : 1;
  unsigned int ipv6_traffic : 1;
  unsigned int prefer_ipv6 : 1;
  unsigned int dns_request : 1;
  unsigned int onion_traffic : 1;

  /** For a socks listener: should we cache IPv4/IPv6 DNS information that
   * exit nodes tell us?
   *
   * @{ */
  unsigned int cache_ipv4_answers : 1;
  unsigned int cache_ipv6_answers : 1;
  /** @} */
  /** For a socks listeners: if we find an answer in our client-side DNS cache,
   * should we use it?
   *
   * @{ */
  unsigned int use_cached_ipv4_answers : 1;
  unsigned int use_cached_ipv6_answers : 1;
  /** @} */
  /** For socks listeners: When we can automap an address to IPv4 or IPv6,
   * do we prefer IPv6? */
  unsigned int prefer_ipv6_virtaddr : 1;

  /** For socks listeners: can we send back the extended SOCKS5 error code? */
  unsigned int extended_socks5_codes : 1;

};

#endif /* !defined(ENTRY_PORT_CFG_ST_H) */
