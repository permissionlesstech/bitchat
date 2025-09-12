/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_init.h
 *
 * \brief Headers for crypto_init.c
 **/

#ifndef TOR_CRYPTO_INIT_H
#define TOR_CRYPTO_INIT_H

#include "orconfig.h"
#include "lib/cc/compat_compiler.h"

int crypto_init_siphash_key(void);
int crypto_early_init(void) ATTR_WUR;
int crypto_global_init(int hardwareAccel,
                       const char *accelName,
                       const char *accelPath) ATTR_WUR;

void crypto_thread_cleanup(void);
int crypto_global_cleanup(void);
void crypto_prefork(void);
void crypto_postfork(void);

const char *crypto_get_library_name(void);
const char *crypto_get_library_version_string(void);
const char *crypto_get_header_version_string(void);

int tor_is_using_nss(void);

#endif /* !defined(TOR_CRYPTO_INIT_H) */
