/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_digest.h
 *
 * \brief Headers for crypto_digest.c
 **/

#ifndef TOR_CRYPTO_DIGEST_H
#define TOR_CRYPTO_DIGEST_H

#include "lib/cc/torint.h"
#include "lib/defs/digest_sizes.h"
#include "lib/malloc/malloc.h"
#include "lib/testsupport/testsupport.h"

/** Length of a sha1 message digest when encoded in base32 with trailing =
 * signs removed. */
#define BASE32_DIGEST_LEN 32
/** Length of a sha1 message digest when encoded in base64 with trailing =
 * signs removed. */
#define BASE64_DIGEST_LEN 27
/** Length of a sha256 message digest when encoded in base64 with trailing =
 * signs removed. */
#define BASE64_DIGEST256_LEN 43
/** Length of a sha512 message digest when encoded in base64 with trailing =
 * signs removed. */
#define BASE64_DIGEST512_LEN 86

/** Length of hex encoding of SHA1 digest, not including final NUL. */
#define HEX_DIGEST_LEN 40
/** Length of hex encoding of SHA256 digest, not including final NUL. */
#define HEX_DIGEST256_LEN 64
/** Length of hex encoding of SHA512 digest, not including final NUL. */
#define HEX_DIGEST512_LEN 128

/**
 * An identifier for a cryptographic digest algorithm.
 **/
typedef enum {
  DIGEST_SHA1 = 0,
  DIGEST_SHA256 = 1,
  DIGEST_SHA512 = 2,
  DIGEST_SHA3_256 = 3,
  DIGEST_SHA3_512 = 4,
} digest_algorithm_t;
/** Number of digest algorithms that we know */
#define  N_DIGEST_ALGORITHMS (DIGEST_SHA3_512+1)
/** Number of digest algorithms to compute when computing "all the
 * commonly used digests."
 *
 * (This is used in common_digests_t and related functions.)
 */
#define  N_COMMON_DIGEST_ALGORITHMS (DIGEST_SHA256+1)

/**
 * Bytes of storage needed to record the state of an in-progress SHA-1 digest.
 *
 * This is a deliberate overestimate.
 **/
#define DIGEST_CHECKPOINT_BYTES (SIZEOF_VOID_P + 512)

/** Structure used to temporarily save the a digest object. Only implemented
 * for SHA1 digest for now. */
typedef struct crypto_digest_checkpoint_t {
#ifdef ENABLE_NSS
  /** The number of bytes used in <b>mem</b>. */
  unsigned int bytes_used;
#endif
  /** A buffer to store the SHA1 state. Its contents are unspecified, and
   * are managed by the underlying crypto library.*/
  uint8_t mem[DIGEST_CHECKPOINT_BYTES];
} crypto_digest_checkpoint_t;

/** A set of all the digests we commonly compute, taken on a single
 * string.  Any digests that are shorter than 512 bits are right-padded
 * with 0 bits.
 *
 * Note that this representation wastes 44 bytes for the SHA1 case, so
 * don't use it for anything where we need to allocate a whole bunch at
 * once.
 **/
typedef struct {
  /** An array of digest outputs, one for each "common" digest algorithm. */
  char d[N_COMMON_DIGEST_ALGORITHMS][DIGEST256_LEN];
} common_digests_t;

/**
 * State for computing a digest over a stream of data.
 **/
typedef struct crypto_digest_t crypto_digest_t;

/**
 * State for computing an "extendable-output function" (like SHAKE) over a
 * stream of data, and/or streaming the output.
 **/
typedef struct crypto_xof_t crypto_xof_t;

struct smartlist_t;

/* SHA-1 and other digests */
MOCK_DECL(int, crypto_digest,(char *digest, const char *m, size_t len));
int crypto_digest256(char *digest, const char *m, size_t len,
                     digest_algorithm_t algorithm);
int crypto_digest512(char *digest, const char *m, size_t len,
                     digest_algorithm_t algorithm);
int crypto_common_digests(common_digests_t *ds_out, const char *m, size_t len);
void crypto_digest_smartlist_prefix(char *digest_out, size_t len_out,
                                    const char *prepend,
                                    const struct smartlist_t *lst,
                                    const char *append,
                                    digest_algorithm_t alg);
void crypto_digest_smartlist(char *digest_out, size_t len_out,
                             const struct smartlist_t *lst, const char *append,
                             digest_algorithm_t alg);
const char *crypto_digest_algorithm_get_name(digest_algorithm_t alg);
size_t crypto_digest_algorithm_get_length(digest_algorithm_t alg);
int crypto_digest_algorithm_parse_name(const char *name);
crypto_digest_t *crypto_digest_new(void);
crypto_digest_t *crypto_digest256_new(digest_algorithm_t algorithm);
crypto_digest_t *crypto_digest512_new(digest_algorithm_t algorithm);
void crypto_digest_free_(crypto_digest_t *digest);
/**
 * Release all storage held in <b>d</b>, and set it to NULL.
 **/
#define crypto_digest_free(d) \
  FREE_AND_NULL(crypto_digest_t, crypto_digest_free_, (d))
void crypto_digest_add_bytes(crypto_digest_t *digest, const char *data,
                             size_t len);
void crypto_digest_get_digest(crypto_digest_t *digest,
                              char *out, size_t out_len);
crypto_digest_t *crypto_digest_dup(const crypto_digest_t *digest);
void crypto_digest_checkpoint(crypto_digest_checkpoint_t *checkpoint,
                              const crypto_digest_t *digest);
void crypto_digest_restore(crypto_digest_t *digest,
                           const crypto_digest_checkpoint_t *checkpoint);
void crypto_digest_assign(crypto_digest_t *into,
                          const crypto_digest_t *from);
void crypto_hmac_sha256(char *hmac_out,
                        const char *key, size_t key_len,
                        const char *msg, size_t msg_len);
void crypto_mac_sha3_256(uint8_t *mac_out, size_t len_out,
                         const uint8_t *key, size_t key_len,
                         const uint8_t *msg, size_t msg_len);

/* xof functions*/
crypto_xof_t *crypto_xof_new(void);
void crypto_xof_add_bytes(crypto_xof_t *xof, const uint8_t *data, size_t len);
void crypto_xof_squeeze_bytes(crypto_xof_t *xof, uint8_t *out, size_t len);
void crypto_xof_free_(crypto_xof_t *xof);
/**
 * Release all storage held in <b>xof</b>, and set it to NULL.
 **/
#define crypto_xof_free(xof) \
  FREE_AND_NULL(crypto_xof_t, crypto_xof_free_, (xof))
void crypto_xof(uint8_t *output, size_t output_len,
                const uint8_t *input, size_t input_len);

#ifdef TOR_UNIT_TESTS
digest_algorithm_t crypto_digest_get_algorithm(crypto_digest_t *digest);
#endif

#endif /* !defined(TOR_CRYPTO_DIGEST_H) */
