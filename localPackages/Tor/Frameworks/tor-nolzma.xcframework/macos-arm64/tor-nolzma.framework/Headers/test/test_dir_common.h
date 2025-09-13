/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_TEST_DIR_COMMON_H
#define TOR_TEST_DIR_COMMON_H

#include "core/or/or.h"
#include "feature/nodelist/networkstatus.h"

#define TEST_DIR_ROUTER_ID_1 3
#define TEST_DIR_ROUTER_ID_2 5
#define TEST_DIR_ROUTER_ID_3 33
#define TEST_DIR_ROUTER_ID_4 34

#define TEST_DIR_ROUTER_DD_1 78
#define TEST_DIR_ROUTER_DD_2 77
#define TEST_DIR_ROUTER_DD_3 79
#define TEST_DIR_ROUTER_DD_4 44

int dir_common_authority_pk_init(authority_cert_t **cert1,
                       authority_cert_t **cert2,
                       authority_cert_t **cert3,
                       crypto_pk_t **sign_skey_1,
                       crypto_pk_t **sign_skey_2,
                       crypto_pk_t **sign_skey_3);

routerinfo_t * dir_common_generate_ri_from_rs(const vote_routerstatus_t *vrs);

vote_routerstatus_t * dir_common_gen_routerstatus_for_v3ns(int idx,
                                                           time_t now);

int dir_common_construct_vote_1(networkstatus_t **vote,
                        authority_cert_t *cert1,
                        crypto_pk_t *sign_skey,
                        vote_routerstatus_t * (*vrs_gen)(int idx, time_t now),
                        networkstatus_t **vote_out, int *n_vrs, time_t now,
                        int clear_rl);

int dir_common_construct_vote_2(networkstatus_t **vote,
                        authority_cert_t *cert2,
                        crypto_pk_t *sign_skey,
                        vote_routerstatus_t * (*vrs_gen)(int idx, time_t now),
                        networkstatus_t **vote_out, int *n_vrs, time_t now,
                        int clear_rl);

int dir_common_construct_vote_3(networkstatus_t **vote,
                        authority_cert_t *cert3,
                        crypto_pk_t *sign_skey,
                        vote_routerstatus_t * (*vrs_gen)(int idx, time_t now),
                        networkstatus_t **vote_out, int *n_vrs, time_t now,
                        int clear_rl);

#endif /* !defined(TOR_TEST_DIR_COMMON_H) */
