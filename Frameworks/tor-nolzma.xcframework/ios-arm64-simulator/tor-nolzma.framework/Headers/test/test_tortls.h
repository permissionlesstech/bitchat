/* Copyright (c) 2010-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TEST_TORTLS_H
#define TEST_TORTLS_H

tor_x509_cert_impl_t *read_cert_from(const char *str);

extern const char *notCompletelyValidCertString;
extern const char *validCertString;
extern const char *caCertString;

#endif /* !defined(TEST_TORTLS_H) */
