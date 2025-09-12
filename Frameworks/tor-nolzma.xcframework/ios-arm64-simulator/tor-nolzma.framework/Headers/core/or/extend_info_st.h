/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file extend_info_st.h
 * @brief Extend-info structure.
 **/

#ifndef EXTEND_INFO_ST_H
#define EXTEND_INFO_ST_H

#include "lib/crypt_ops/crypto_curve25519.h"
#include "lib/crypt_ops/crypto_ed25519.h"

/** Largest number of addresses we handle in an extend_info.
 *
 * More are permitted in an EXTEND cell, but we won't handle them. */
#define EXTEND_INFO_MAX_ADDRS 2

/** Information on router used when extending a circuit. We don't need a
 * full routerinfo_t to extend: we only need addr:port:keyid to build an OR
 * connection, and onion_key to create the onionskin. Note that for one-hop
 * general-purpose tunnels, the onion_key is NULL. */
struct extend_info_t {
  char nickname[MAX_HEX_NICKNAME_LEN+1]; /**< This router's nickname for
                                          * display. */
  /** Hash of this router's RSA identity key. */
  char identity_digest[DIGEST_LEN];
  /** Ed25519 identity for this router, if any. */
  ed25519_public_key_t ed_identity;
  /** IP/Port values for this hop's ORPort(s).  Any unused values are set
   * to a null address. */
  tor_addr_port_t orports[EXTEND_INFO_MAX_ADDRS];
  /** TAP onion key for this hop. */
  crypto_pk_t *onion_key;
  /** Ntor onion key for this hop. */
  curve25519_public_key_t curve25519_onion_key;
  /** True if this hop is to be used as an _exit_,
   * and it also supports supports NtorV3 _and_ negotiation
   * of congestion control parameters */
  bool exit_supports_congestion_control;
};

#endif /* !defined(EXTEND_INFO_ST_H) */
