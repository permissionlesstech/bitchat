/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_rsa.h
 *
 * \brief Headers for crypto_rsa.c
 **/

#ifndef TOR_CRYPTO_RSA_H
#define TOR_CRYPTO_RSA_H

#include "orconfig.h"

#include "lib/crypt_ops/crypto_digest.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"
#include "lib/log/log.h"

/** Length of our public keys. */
#define PK_BYTES (1024/8)

/** Constant used to indicate OAEP padding for public-key encryption */
#define PK_PKCS1_OAEP_PADDING 60002

/** Number of bytes added for PKCS1-OAEP padding. */
#define PKCS1_OAEP_PADDING_OVERHEAD 42

/** Length of encoded public key fingerprints, including space; but not
 * including terminating NUL. */
#define FINGERPRINT_LEN 49

/** Value of 'e' to use in our public keys */
#define TOR_RSA_EXPONENT 65537

/** A public key, or a public/private key-pair. */
typedef struct crypto_pk_t crypto_pk_t;

/* RSA environment setup */
MOCK_DECL(crypto_pk_t *,crypto_pk_new,(void));
void crypto_pk_free_(crypto_pk_t *env);
#define crypto_pk_free(pk) FREE_AND_NULL(crypto_pk_t, crypto_pk_free_, (pk))
int crypto_get_rsa_padding_overhead(int padding);
int crypto_get_rsa_padding(int padding);

/* public key crypto */
MOCK_DECL(int, crypto_pk_generate_key_with_bits,(crypto_pk_t *env, int bits));
#define crypto_pk_generate_key(env)                     \
  crypto_pk_generate_key_with_bits((env), (PK_BYTES*8))

int crypto_pk_read_private_key_from_filename(crypto_pk_t *env,
                                             const char *keyfile);
int crypto_pk_write_public_key_to_string(crypto_pk_t *env,
                                         char **dest, size_t *len);
int crypto_pk_write_private_key_to_string(crypto_pk_t *env,
                                          char **dest, size_t *len);
int crypto_pk_read_public_key_from_string(crypto_pk_t *env,
                                          const char *src, size_t len);
int crypto_pk_read_private_key_from_string(crypto_pk_t *env,
                                           const char *s, ssize_t len);
int crypto_pk_read_private_key1024_from_string(crypto_pk_t *env,
                                               const char *src, ssize_t len);
int crypto_pk_write_private_key_to_filename(crypto_pk_t *env,
                                            const char *fname);

int crypto_pk_is_valid_private_key(const crypto_pk_t *env);
int crypto_pk_cmp_keys(const crypto_pk_t *a, const crypto_pk_t *b);
int crypto_pk_eq_keys(const crypto_pk_t *a, const crypto_pk_t *b);
size_t crypto_pk_keysize(const crypto_pk_t *env);
int crypto_pk_num_bits(crypto_pk_t *env);
crypto_pk_t *crypto_pk_dup_key(crypto_pk_t *orig);
crypto_pk_t *crypto_pk_copy_full(crypto_pk_t *orig);
int crypto_pk_key_is_private(const crypto_pk_t *key);
int crypto_pk_public_exponent_ok(const crypto_pk_t *env);
int crypto_pk_obsolete_public_hybrid_encrypt(crypto_pk_t *env, char *to,
                                    size_t tolen,
                                    const char *from, size_t fromlen,
                                    int padding, int force);
int crypto_pk_obsolete_private_hybrid_decrypt(crypto_pk_t *env, char *to,
                                     size_t tolen,
                                     const char *from, size_t fromlen,
                                     int padding, int warnOnFailure);
int crypto_pk_public_encrypt(crypto_pk_t *env, char *to, size_t tolen,
                             const char *from, size_t fromlen, int padding);
int crypto_pk_private_decrypt(crypto_pk_t *env, char *to, size_t tolen,
                              const char *from, size_t fromlen,
                              int padding, int warnOnFailure);
MOCK_DECL(int, crypto_pk_public_checksig,(const crypto_pk_t *env,
                                          char *to, size_t tolen,
                                          const char *from, size_t fromlen));
int crypto_pk_private_sign(const crypto_pk_t *env, char *to, size_t tolen,
                           const char *from, size_t fromlen);
int crypto_pk_asn1_encode(const crypto_pk_t *pk, char *dest, size_t dest_len);
crypto_pk_t *crypto_pk_asn1_decode(const char *str, size_t len);
int crypto_pk_asn1_encode_private(const crypto_pk_t *pk,
                                  char *dest, size_t dest_len);
crypto_pk_t *crypto_pk_asn1_decode_private(const char *str, size_t len,
                                           int max_bits);
int crypto_pk_get_fingerprint(crypto_pk_t *pk, char *fp_out,int add_space);
int crypto_pk_get_hashed_fingerprint(crypto_pk_t *pk, char *fp_out);
void crypto_add_spaces_to_fp(char *out, size_t outlen, const char *in);

MOCK_DECL(int, crypto_pk_public_checksig_digest,(crypto_pk_t *env,
          const char *data, size_t datalen, const char *sig, size_t siglen));
int crypto_pk_private_sign_digest(crypto_pk_t *env, char *to, size_t tolen,
                                  const char *from, size_t fromlen);
int crypto_pk_get_digest(const crypto_pk_t *pk, char *digest_out);
int crypto_pk_get_common_digests(crypto_pk_t *pk,
                                 common_digests_t *digests_out);
int crypto_pk_base64_encode_private(const crypto_pk_t *pk, char **priv_out);
crypto_pk_t *crypto_pk_base64_decode_private(const char *str, size_t len);

#ifdef ENABLE_OPENSSL
/* Prototypes for private functions only used by tortls.c, crypto.c, and the
 * unit tests. */
struct rsa_st;
struct evp_pkey_st;
struct rsa_st *crypto_pk_get_openssl_rsa_(crypto_pk_t *env);
crypto_pk_t *crypto_new_pk_from_openssl_rsa_(struct rsa_st *rsa);
MOCK_DECL(struct evp_pkey_st *, crypto_pk_get_openssl_evp_pkey_,(
                                 crypto_pk_t *env,int private));
#endif /* defined(ENABLE_OPENSSL) */

#ifdef ENABLE_NSS
struct SECKEYPublicKeyStr;
struct SECKEYPrivateKeyStr;
crypto_pk_t *crypto_pk_new_from_nss_pubkey(struct SECKEYPublicKeyStr *pub);
const struct SECKEYPublicKeyStr *crypto_pk_get_nss_pubkey(
                                           const crypto_pk_t *key);
const struct SECKEYPrivateKeyStr *crypto_pk_get_nss_privkey(
                                           const crypto_pk_t *key);
#endif /* defined(ENABLE_NSS) */

void crypto_pk_assign_public(crypto_pk_t *dest, const crypto_pk_t *src);
void crypto_pk_assign_private(crypto_pk_t *dest, const crypto_pk_t *src);

#ifdef TOR_UNIT_TESTS
#ifdef ENABLE_NSS
struct SECItemStr;
STATIC int secitem_uint_cmp(const struct SECItemStr *a,
                            const struct SECItemStr *b);
#endif
#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_CRYPTO_RSA_H) */
