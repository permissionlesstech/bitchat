/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file or_handshake_certs_st.h
 * @brief OR handshake certs structure
 **/

#ifndef OR_HANDSHAKE_CERTS_ST
#define OR_HANDSHAKE_CERTS_ST

struct tor_x509_cert_t;

/** Structure to hold all the certificates we've received on an OR connection
 */
struct or_handshake_certs_t {
  /** True iff we originated this connection. */
  int started_here;
  /** The cert for the 'auth' RSA key that's supposed to sign the AUTHENTICATE
   * cell. Signed with the RSA identity key. */
  struct tor_x509_cert_t *auth_cert;
  /** The cert for the 'link' RSA key that was used to negotiate the TLS
   *  connection.  Signed with the RSA identity key. */
  struct tor_x509_cert_t *link_cert;
  /** A self-signed identity certificate: the RSA identity key signed
   * with itself.  */
  struct tor_x509_cert_t *id_cert;
  /** The Ed25519 signing key, signed with the Ed25519 identity key. */
  struct tor_cert_st *ed_id_sign;
  /** A digest of the X509 link certificate for the TLS connection, signed
   * with the Ed25519 siging key. */
  struct tor_cert_st *ed_sign_link;
  /** The Ed25519 authentication key (that's supposed to sign an AUTHENTICATE
   * cell) , signed with the Ed25519 siging key. */
  struct tor_cert_st *ed_sign_auth;
  /** The Ed25519 identity key, crosssigned with the RSA identity key. */
  uint8_t *ed_rsa_crosscert;
  /** The length of <b>ed_rsa_crosscert</b> in bytes */
  size_t ed_rsa_crosscert_len;
};

#endif /* !defined(OR_HANDSHAKE_CERTS_ST) */
