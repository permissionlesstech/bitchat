/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_crypto_st.h
 * @brief Relay-cell encryption state structure.
 **/

#ifndef RELAY_CRYPTO_ST_H
#define RELAY_CRYPTO_ST_H

#define crypto_cipher_t aes_cnt_cipher_t
struct crypto_cipher_t;
struct crypto_digest_t;

struct relay_crypto_t {
  /* crypto environments */
  /** Encryption key and counter for cells heading towards the OR at this
   * step. */
  struct crypto_cipher_t *f_crypto;
  /** Encryption key and counter for cells heading back from the OR at this
   * step. */
  struct crypto_cipher_t *b_crypto;

  /** Digest state for cells heading towards the OR at this step. */
  struct crypto_digest_t *f_digest; /* for integrity checking */
  /** Digest state for cells heading away from the OR at this step. */
  struct crypto_digest_t *b_digest;

  /** Digest used for the next SENDME cell if any. */
  uint8_t sendme_digest[DIGEST_LEN];
};
#undef crypto_cipher_t

#endif /* !defined(RELAY_CRYPTO_ST_H) */
