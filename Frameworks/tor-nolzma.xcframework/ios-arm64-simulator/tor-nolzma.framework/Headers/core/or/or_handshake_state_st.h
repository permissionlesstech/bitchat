/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file or_handshake_state_st.h
 * @brief OR handshake state structure
 **/

#ifndef OR_HANDSHAKE_STATE_ST
#define OR_HANDSHAKE_STATE_ST

/** Stores flags and information related to the portion of a v2/v3 Tor OR
 * connection handshake that happens after the TLS handshake is finished.
 */
struct or_handshake_state_t {
  /** When was the VERSIONS cell sent on this connection?  Used to get
   * an estimate of the skew in the returning NETINFO reply. */
  time_t sent_versions_at;
  /** True iff we originated this connection */
  unsigned int started_here : 1;
  /** True iff we have received and processed a VERSIONS cell. */
  unsigned int received_versions : 1;
  /** True iff we have received and processed an AUTH_CHALLENGE cell */
  unsigned int received_auth_challenge : 1;
  /** True iff we have received and processed a CERTS cell. */
  unsigned int received_certs_cell : 1;
  /** True iff we have received and processed an AUTHENTICATE cell */
  unsigned int received_authenticate : 1;

  /* True iff we've received valid authentication to some identity. */
  unsigned int authenticated : 1;
  unsigned int authenticated_rsa : 1;
  unsigned int authenticated_ed25519 : 1;

  /* True iff we have sent a netinfo cell */
  unsigned int sent_netinfo : 1;

  /** The signing->ed25519 link certificate corresponding to the x509
   * certificate we used on the TLS connection (if this is a server-side
   * connection). We make a copy of this here to prevent a race condition
   * caused by TLS context rotation. */
  struct tor_cert_st *own_link_cert;

  /** True iff we should feed outgoing cells into digest_sent and
   * digest_received respectively.
   *
   * From the server's side of the v3 handshake, we want to capture everything
   * from the VERSIONS cell through and including the AUTH_CHALLENGE cell.
   * From the client's, we want to capture everything from the VERSIONS cell
   * through but *not* including the AUTHENTICATE cell.
   *
   * @{ */
  unsigned int digest_sent_data : 1;
  unsigned int digest_received_data : 1;
  /**@}*/

  /** Identity RSA digest that we have received and authenticated for our peer
   * on this connection. */
  uint8_t authenticated_rsa_peer_id[DIGEST_LEN];
  /** Identity Ed25519 public key that we have received and authenticated for
   * our peer on this connection. */
  ed25519_public_key_t authenticated_ed25519_peer_id;

  /** Digests of the cells that we have sent or received as part of a V3
   * handshake.  Used for making and checking AUTHENTICATE cells.
   *
   * @{
   */
  crypto_digest_t *digest_sent;
  crypto_digest_t *digest_received;
  /** @} */

  /** Certificates that a connection initiator sent us in a CERTS cell; we're
   * holding on to them until we get an AUTHENTICATE cell.
   */
  or_handshake_certs_t *certs;
};

#endif /* !defined(OR_HANDSHAKE_STATE_ST) */
