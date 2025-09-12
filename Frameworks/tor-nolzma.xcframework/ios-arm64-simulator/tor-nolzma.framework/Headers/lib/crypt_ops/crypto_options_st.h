/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file crypto_options_st.h
 * @brief Header for lib/crypt_ops/crypto_options_st.c
 **/

#ifndef TOR_LIB_CRYPT_OPS_CRYPTO_OPTIONS_ST_H
#define TOR_LIB_CRYPT_OPS_CRYPTO_OPTIONS_ST_H

#include "lib/conf/confdecl.h"

#define CONF_CONTEXT STRUCT
#include "lib/crypt_ops/crypto_options.inc"
#undef CONF_CONTEXT

typedef struct crypto_options_t crypto_options_t;

#endif /* !defined(TOR_LIB_CRYPT_OPS_CRYPTO_OPTIONS_ST_H) */
