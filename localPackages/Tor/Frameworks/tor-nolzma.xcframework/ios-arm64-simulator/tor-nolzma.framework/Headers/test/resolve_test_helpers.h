/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file resolve_test_helpers.h
 * @brief Header for test/resolve_test_helpers.c
 **/

#ifndef TOR_TEST_RESOLVE_TEST_HELPERS_H
#define TOR_TEST_RESOLVE_TEST_HELPERS_H

void mock_hostname_resolver(void);
void unmock_hostname_resolver(void);

#endif /* !defined(TOR_TEST_RESOLVE_TEST_HELPERS_H) */
