/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_X509_INTERNAL_H
#define TOR_X509_INTERNAL_H

/**
 * \file x509.h
 * \brief Internal headers for tortls.c
 **/

#include "lib/crypt_ops/crypto_rsa.h"
#include "lib/testsupport/testsupport.h"

/**
 * How skewed do we allow our clock to be with respect to certificates that
 * seem to be expired? (seconds)
 */
#define TOR_X509_PAST_SLOP (2*24*60*60)
/**
 * How skewed do we allow our clock to be with respect to certificates that
 * seem to come from the future? (seconds)
 */
#define  TOR_X509_FUTURE_SLOP (30*24*60*60)

MOCK_DECL(tor_x509_cert_impl_t *, tor_tls_create_certificate,
                                                   (crypto_pk_t *rsa,
                                                    crypto_pk_t *rsa_sign,
                                                    const char *cname,
                                                    const char *cname_sign,
                                                  unsigned int cert_lifetime));
MOCK_DECL(tor_x509_cert_t *, tor_x509_cert_new,
          (tor_x509_cert_impl_t *x509_cert));

int tor_x509_check_cert_lifetime_internal(int severity,
                                          const tor_x509_cert_impl_t *cert,
                                          time_t now,
                                          int past_tolerance,
                                          int future_tolerance);

void tor_x509_cert_impl_free_(tor_x509_cert_impl_t *cert);
#define tor_x509_cert_impl_free(cert) \
  FREE_AND_NULL(tor_x509_cert_impl_t, tor_x509_cert_impl_free_, (cert))
tor_x509_cert_impl_t *tor_x509_cert_impl_dup_(tor_x509_cert_impl_t *cert);
#ifdef ENABLE_OPENSSL
int tor_x509_cert_set_cached_der_encoding(tor_x509_cert_t *cert);
#else
#define tor_x509_cert_set_cached_der_encoding(cert) (0)
#endif

#endif /* !defined(TOR_X509_INTERNAL_H) */
