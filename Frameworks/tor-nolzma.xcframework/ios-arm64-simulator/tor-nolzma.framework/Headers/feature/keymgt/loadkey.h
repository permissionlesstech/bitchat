/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file loadkey.h
 * \brief Header file for loadkey.c
 **/

#ifndef TOR_LOADKEY_H
#define TOR_LOADKEY_H

#include "lib/crypt_ops/crypto_ed25519.h"

crypto_pk_t *init_key_from_file(const char *fname, int generate,
                                int severity, bool *created_out);

#define INIT_ED_KEY_CREATE                      (1u<<0)
#define INIT_ED_KEY_REPLACE                     (1u<<1)
#define INIT_ED_KEY_SPLIT                       (1u<<2)
#define INIT_ED_KEY_MISSING_SECRET_OK           (1u<<3)
#define INIT_ED_KEY_NEEDCERT                    (1u<<4)
#define INIT_ED_KEY_EXTRA_STRONG                (1u<<5)
#define INIT_ED_KEY_INCLUDE_SIGNING_KEY_IN_CERT (1u<<6)
#define INIT_ED_KEY_OMIT_SECRET                 (1u<<7)
#define INIT_ED_KEY_TRY_ENCRYPTED               (1u<<8)
#define INIT_ED_KEY_NO_REPAIR                   (1u<<9)
#define INIT_ED_KEY_SUGGEST_KEYGEN              (1u<<10)
#define INIT_ED_KEY_OFFLINE_SECRET              (1u<<11)
#define INIT_ED_KEY_EXPLICIT_FNAME              (1u<<12)

struct tor_cert_st;
ed25519_keypair_t *ed_key_init_from_file(const char *fname, uint32_t flags,
                                         int severity,
                                         const ed25519_keypair_t *signing_key,
                                         time_t now,
                                         time_t lifetime,
                                         uint8_t cert_type,
                                         struct tor_cert_st **cert_out,
                                         const or_options_t *options);
ed25519_keypair_t *ed_key_new(const ed25519_keypair_t *signing_key,
                              uint32_t flags,
                              time_t now,
                              time_t lifetime,
                              uint8_t cert_type,
                              struct tor_cert_st **cert_out);

int read_encrypted_secret_key(ed25519_secret_key_t *out,
                              const char *fname);
int write_encrypted_secret_key(const ed25519_secret_key_t *out,
                               const char *fname);

#endif /* !defined(TOR_LOADKEY_H) */
