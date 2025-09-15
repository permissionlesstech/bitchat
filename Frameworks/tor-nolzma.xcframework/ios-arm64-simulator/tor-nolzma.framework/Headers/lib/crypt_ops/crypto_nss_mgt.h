/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_nss_mgt.h
 *
 * \brief Headers for crypto_nss_mgt.c
 **/

#ifndef TOR_CRYPTO_NSS_MGT_H
#define TOR_CRYPTO_NSS_MGT_H

#include "orconfig.h"

#ifdef ENABLE_NSS
/* global nss state */
const char *crypto_nss_get_version_str(void);
const char *crypto_nss_get_header_version_str(void);

void crypto_nss_log_errors(int severity, const char *doing);

void crypto_nss_early_init(int nss_only);
int crypto_nss_late_init(void);

void crypto_nss_global_cleanup(void);

void crypto_nss_prefork(void);
void crypto_nss_postfork(void);
#endif /* defined(ENABLE_NSS) */

#endif /* !defined(TOR_CRYPTO_NSS_MGT_H) */
