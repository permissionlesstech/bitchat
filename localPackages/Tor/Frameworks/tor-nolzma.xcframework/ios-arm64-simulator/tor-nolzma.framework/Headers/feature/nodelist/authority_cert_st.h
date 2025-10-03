/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file authority_cert_st.h
 * @brief Authority certificate structure.
 **/

#ifndef AUTHORITY_CERT_ST_H
#define AUTHORITY_CERT_ST_H

#include "feature/nodelist/signed_descriptor_st.h"

/** Certificate for v3 directory protocol: binds long-term authority identity
 * keys to medium-term authority signing keys. */
struct authority_cert_t {
  /** Information relating to caching this cert on disk and looking it up. */
  signed_descriptor_t cache_info;
  /** This authority's long-term authority identity key. */
  crypto_pk_t *identity_key;
  /** This authority's medium-term signing key. */
  crypto_pk_t *signing_key;
  /** The digest of <b>signing_key</b> */
  char signing_key_digest[DIGEST_LEN];
  /** The listed expiration time of this certificate. */
  time_t expires;
  /** This authority's IPv4 address. */
  tor_addr_t ipv4_addr;
  /** This authority's directory port. */
  uint16_t ipv4_dirport;
};

#endif /* !defined(AUTHORITY_CERT_ST_H) */
