/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_handshake.h
 * @brief Header for feature/relay/relay_handshake.c
 **/

#ifndef TOR_CORE_OR_RELAY_HANDSHAKE_H
#define TOR_CORE_OR_RELAY_HANDSHAKE_H

#ifdef HAVE_MODULE_RELAY
struct ed25519_keypair_t;

int connection_or_send_certs_cell(or_connection_t *conn);
int connection_or_send_auth_challenge_cell(or_connection_t *conn);

var_cell_t *connection_or_compute_authenticate_cell_body(
                              or_connection_t *conn,
                              const int authtype,
                              crypto_pk_t *signing_key,
                              const struct ed25519_keypair_t *ed_signing_key,
                              int server);

int authchallenge_type_is_supported(uint16_t challenge_type);
int authchallenge_type_is_better(uint16_t challenge_type_a,
                                 uint16_t challenge_type_b);

MOCK_DECL(int,connection_or_send_authenticate_cell,
          (or_connection_t *conn, int type));

#ifdef TOR_UNIT_TESTS
extern int certs_cell_ed25519_disabled_for_testing;
#endif
#else /* !defined(HAVE_MODULE_RELAY) */

static inline int
connection_or_send_certs_cell(or_connection_t *conn)
{
  (void)conn;
  tor_assert_nonfatal_unreached();
  return -1;
}
static inline int
connection_or_send_auth_challenge_cell(or_connection_t *conn)
{
  (void)conn;
  tor_assert_nonfatal_unreached();
  return -1;
}

static inline var_cell_t *
connection_or_compute_authenticate_cell_body(
                              or_connection_t *conn,
                              const int authtype,
                              crypto_pk_t *signing_key,
                              const struct ed25519_keypair_t *ed_signing_key,
                              int server)
{
  (void)conn;
  (void)authtype;
  (void)signing_key;
  (void)ed_signing_key;
  (void)server;
  tor_assert_nonfatal_unreached();
  return NULL;
}

#define authchallenge_type_is_supported(t) (0)
#define authchallenge_type_is_better(a, b) (0)

static inline int
connection_or_send_authenticate_cell(or_connection_t *conn, int type)
{
  (void)conn;
  (void)type;
  tor_assert_nonfatal_unreached();
  return -1;
}

#ifdef TOR_UNIT_TESTS
extern int certs_cell_ed25519_disabled_for_testing;
#endif

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_CORE_OR_RELAY_HANDSHAKE_H) */
