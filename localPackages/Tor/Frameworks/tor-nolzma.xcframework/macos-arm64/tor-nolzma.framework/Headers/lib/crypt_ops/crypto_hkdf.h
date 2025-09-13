/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_hkdf.h
 *
 * \brief Headers for crypto_hkdf.h
 **/

#ifndef TOR_CRYPTO_HKDF_H
#define TOR_CRYPTO_HKDF_H

#include "lib/cc/torint.h"

int crypto_expand_key_material_TAP(const uint8_t *key_in,
                                   size_t key_in_len,
                                   uint8_t *key_out, size_t key_out_len);
int crypto_expand_key_material_rfc5869_sha256(
                                    const uint8_t *key_in, size_t key_in_len,
                                    const uint8_t *salt_in, size_t salt_in_len,
                                    const uint8_t *info_in, size_t info_in_len,
                                    uint8_t *key_out, size_t key_out_len);

#endif /* !defined(TOR_CRYPTO_HKDF_H) */
