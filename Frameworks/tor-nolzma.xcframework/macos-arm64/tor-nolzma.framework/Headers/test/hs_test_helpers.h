/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_HS_TEST_HELPERS_H
#define TOR_HS_TEST_HELPERS_H

#include "trunnel/ed25519_cert.h"
#include "feature/hs/hs_descriptor.h"

/* Set of functions to help build and test descriptors. */
hs_desc_intro_point_t *
hs_helper_build_intro_point(const ed25519_keypair_t *signing_kp, time_t now,
                            const char *addr, int legacy,
                            const ed25519_keypair_t *intro_auth_kp,
                            const curve25519_keypair_t *intro_enc_kp);
hs_descriptor_t *hs_helper_build_hs_desc_no_ip(
                                 const ed25519_keypair_t *signing_kp);
hs_descriptor_t *hs_helper_build_hs_desc_with_ip(
                                 const ed25519_keypair_t *signing_kp);
hs_descriptor_t *
hs_helper_build_hs_desc_with_rev_counter(const ed25519_keypair_t *signing_kp,
                                         uint64_t revision_counter);

hs_descriptor_t *hs_helper_build_hs_desc_with_client_auth(
                                 const uint8_t *descriptor_cookie,
                                 const curve25519_public_key_t *client_pk,
                                 const ed25519_keypair_t *signing_kp);
void hs_helper_desc_equal(const hs_descriptor_t *desc1,
                          const hs_descriptor_t *desc2);
struct hs_subcredential_t;
void hs_helper_get_subcred_from_identity_keypair(ed25519_keypair_t *signing_kp,
                                      struct hs_subcredential_t *subcred_out);

void hs_helper_add_client_auth(const ed25519_public_key_t *service_pk,
                               const curve25519_secret_key_t *client_sk);

#endif /* !defined(TOR_HS_TEST_HELPERS_H) */
