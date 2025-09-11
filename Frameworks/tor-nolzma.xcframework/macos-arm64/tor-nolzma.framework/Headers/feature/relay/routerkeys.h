/* Copyright (c) 2014-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file routerkeys.h
 * @brief Header for routerkeys.c
 **/

#ifndef TOR_ROUTERKEYS_H
#define TOR_ROUTERKEYS_H

#include "lib/crypt_ops/crypto_ed25519.h"

#ifdef HAVE_MODULE_RELAY

const ed25519_public_key_t *get_master_identity_key(void);
MOCK_DECL(const ed25519_keypair_t *, get_master_signing_keypair,(void));
MOCK_DECL(const struct tor_cert_st *, get_master_signing_key_cert,(void));

const ed25519_keypair_t *get_current_auth_keypair(void);
const struct tor_cert_st *get_current_link_cert_cert(void);
const struct tor_cert_st *get_current_auth_key_cert(void);

void get_master_rsa_crosscert(const uint8_t **cert_out,
                              size_t *size_out);

int router_ed25519_id_is_me(const ed25519_public_key_t *id);

/* These are only used by router.c */
struct tor_cert_st *make_ntor_onion_key_crosscert(
                                  const curve25519_keypair_t *onion_key,
                                  const ed25519_public_key_t *master_id_key,
                                  time_t now, time_t lifetime,
                                  int *sign_out);
uint8_t *make_tap_onion_key_crosscert(const crypto_pk_t *onion_key,
                                  const ed25519_public_key_t *master_id_key,
                                  const crypto_pk_t *rsa_id_key,
                                  int *len_out);

int log_cert_expiration(void);
int load_ed_keys(const or_options_t *options, time_t now);
int should_make_new_ed_keys(const or_options_t *options, const time_t now);

int generate_ed_link_cert(const or_options_t *options, time_t now, int force);

void routerkeys_free_all(void);

#else /* !defined(HAVE_MODULE_RELAY) */

#define router_ed25519_id_is_me(id) \
  ((void)(id), 0)

static inline void *
relay_key_is_unavailable_(void)
{
  return NULL;
}
#define relay_key_is_unavailable(type) \
  ((type)(relay_key_is_unavailable_()))

// Many of these can be removed once relay_handshake.c is relay-only.
#define get_current_auth_keypair() \
  relay_key_is_unavailable(const ed25519_keypair_t *)
#define get_master_signing_keypair() \
  relay_key_is_unavailable(const ed25519_keypair_t *)
#define get_current_link_cert_cert() \
  relay_key_is_unavailable(const struct tor_cert_st *)
#define get_current_auth_key_cert() \
  relay_key_is_unavailable(const struct tor_cert_st *)
#define get_master_signing_key_cert() \
  relay_key_is_unavailable(const struct tor_cert_st *)
#define get_master_rsa_crosscert(cert_out, size_out) \
  STMT_BEGIN                                         \
  tor_assert_nonfatal_unreached();                   \
  *(cert_out) = NULL;                                \
  *(size_out) = 0;                                   \
  STMT_END
#define get_master_identity_key() \
  relay_key_is_unavailable(const ed25519_public_key_t *)

#define generate_ed_link_cert(options, now, force) \
  ((void)(options), (void)(now), (void)(force), 0)
#define should_make_new_ed_keys(options, now) \
  ((void)(options), (void)(now), 0)

// These can get removed once router.c becomes relay-only.
static inline struct tor_cert_st *
make_ntor_onion_key_crosscert(const curve25519_keypair_t *onion_key,
                              const ed25519_public_key_t *master_id_key,
                              time_t now, time_t lifetime,
                              int *sign_out)
{
  (void)onion_key;
  (void)master_id_key;
  (void)now;
  (void)lifetime;
  *sign_out = 0;
  tor_assert_nonfatal_unreached();
  return NULL;
}
static inline uint8_t *
make_tap_onion_key_crosscert(const crypto_pk_t *onion_key,
                             const ed25519_public_key_t *master_id_key,
                             const crypto_pk_t *rsa_id_key,
                             int *len_out)
{
  (void)onion_key;
  (void)master_id_key;
  (void)rsa_id_key;
  *len_out = 0;
  tor_assert_nonfatal_unreached();
  return NULL;
}

/* This calls is used outside of relay mode, but only to implement
 * CMD_KEY_EXPIRATION */
#define log_cert_expiration()                                           \
  (puts("Not available: Tor has been compiled without relay support"), 0)
/* This calls is used outside of relay mode, but only to implement
 * CMD_KEYGEN. */
#define load_ed_keys(x,y)                                                \
  (puts("Not available: Tor has been compiled without relay support"), 0)

#endif /* defined(HAVE_MODULE_RELAY) */

#ifdef TOR_UNIT_TESTS
const ed25519_keypair_t *get_master_identity_keypair(void);
void init_mock_ed_keys(const crypto_pk_t *rsa_identity_key);
#endif

#endif /* !defined(TOR_ROUTERKEYS_H) */
