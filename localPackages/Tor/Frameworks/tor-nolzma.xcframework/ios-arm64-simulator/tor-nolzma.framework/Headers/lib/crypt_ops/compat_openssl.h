/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_COMPAT_OPENSSL_H
#define TOR_COMPAT_OPENSSL_H

#include "orconfig.h"

#ifdef ENABLE_OPENSSL

#include <openssl/opensslv.h>
#include "lib/crypt_ops/crypto_openssl_mgt.h"

/**
 * \file compat_openssl.h
 *
 * \brief compatibility definitions for working with different openssl forks
 **/

#if OPENSSL_VERSION_NUMBER < OPENSSL_V_SERIES(1,0,1)
#error "We require OpenSSL >= 1.0.1"
#endif

#if OPENSSL_VERSION_NUMBER >= OPENSSL_V_SERIES(1,1,0)
/* We define this macro if we're trying to build with the majorly refactored
 * API in OpenSSL 1.1 */
#define OPENSSL_1_1_API
#endif /* OPENSSL_VERSION_NUMBER >= OPENSSL_V_SERIES(1,1,0) && ... */

/* LibreSSL claims to be OpenSSL 2.0 but lacks these OpenSSL 1.1 APIs */
#if !defined(OPENSSL_1_1_API) || defined(LIBRESSL_VERSION_NUMBER)
#define RAND_OpenSSL() RAND_SSLeay()
#define STATE_IS_SW_SERVER_HELLO(st)       \
  (((st) == SSL3_ST_SW_SRVR_HELLO_A) ||    \
   ((st) == SSL3_ST_SW_SRVR_HELLO_B))
#define OSSL_HANDSHAKE_STATE int
#else
#define STATE_IS_SW_SERVER_HELLO(st) \
  ((st) == TLS_ST_SW_SRVR_HELLO)
#endif

#if !defined(OPENSSL_1_1_API) || (defined(LIBRESSL_VERSION_NUMBER) && \
   LIBRESSL_VERSION_NUMBER < 0x4010000fL)
#define CONST_IF_OPENSSL_1_1_API
#else
#define CONST_IF_OPENSSL_1_1_API const
#endif

/* OpenSSL 1.1 and LibreSSL both have these APIs */
#ifndef OPENSSL_1_1_API
#define OpenSSL_version(v) SSLeay_version(v)
#define tor_OpenSSL_version_num() SSLeay()
#else /* defined(OPENSSL_1_1_API) */
#define tor_OpenSSL_version_num() OpenSSL_version_num()
#endif /* !defined(OPENSSL_1_1_API) */

#endif /* defined(ENABLE_OPENSSL) */

#endif /* !defined(TOR_COMPAT_OPENSSL_H) */
