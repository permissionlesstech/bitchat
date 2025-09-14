/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file opts_testing_helpers.h
 * @brief Header for test/opts_test_helpers.c
 **/

#ifndef TOR_TEST_OPTS_TESTING_HELPERS_H
#define TOR_TEST_OPTS_TESTING_HELPERS_H

struct crypto_options_t;
struct dirauth_options_t;
struct or_options_t;

struct crypto_options_t *get_crypto_options(struct or_options_t *opt);
struct dirauth_options_t *get_dirauth_options(struct or_options_t *opt);

#endif /* !defined(TOR_TEST_OPTS_TESTING_HELPERS_H) */
