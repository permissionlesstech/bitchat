/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_format.h
 * \brief Header for crypto_format.c
 **/

#ifndef TOR_CRYPTO_FORMAT_H
#define TOR_CRYPTO_FORMAT_H

#include "lib/testsupport/testsupport.h"
#include "lib/cc/torint.h"
#include "lib/defs/x25519_sizes.h"

struct ed25519_public_key_t;
struct ed25519_signature_t;

int crypto_write_tagged_contents_to_file(const char *fname,
                                         const char *typestring,
                                         const char *tag,
                                         const uint8_t *data,
                                         size_t datalen);

ssize_t crypto_read_tagged_contents_from_file(const char *fname,
                                              const char *typestring,
                                              char **tag_out,
                                              uint8_t *data_out,
                                              ssize_t data_out_len);

int ed25519_public_from_base64(struct ed25519_public_key_t *pkey,
                               const char *input);
void ed25519_public_to_base64(char *output,
                              const struct ed25519_public_key_t *pkey);
const char *ed25519_fmt(const struct ed25519_public_key_t *pkey);

int ed25519_signature_from_base64(struct ed25519_signature_t *sig,
                                  const char *input);
void ed25519_signature_to_base64(char *output,
                                 const struct ed25519_signature_t *sig);

void digest_to_base64(char *d64, const char *digest);
int digest_from_base64(char *digest, const char *d64);
void digest256_to_base64(char *d64, const char *digest);
int digest256_from_base64(char *digest, const char *d64);

#endif /* !defined(TOR_CRYPTO_FORMAT_H) */
