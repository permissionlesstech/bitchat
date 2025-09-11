/* Copyright (c) 2014-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_pwbox.h
 *
 * \brief Header for crypto_pwbox.c
 **/

#ifndef CRYPTO_PWBOX_H_INCLUDED_
#define CRYPTO_PWBOX_H_INCLUDED_

#include "lib/cc/torint.h"

#define UNPWBOX_OKAY 0
#define UNPWBOX_BAD_SECRET -1
#define UNPWBOX_CORRUPTED -2

int crypto_pwbox(uint8_t **out, size_t *outlen_out,
                 const uint8_t *inp, size_t input_len,
                 const char *secret, size_t secret_len,
                 unsigned s2k_flags);

int crypto_unpwbox(uint8_t **out, size_t *outlen_out,
                   const uint8_t *inp, size_t input_len,
                   const char *secret, size_t secret_len);

#endif /* !defined(CRYPTO_PWBOX_H_INCLUDED_) */
