/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file tor_cmdline_mode.h
 * \brief Declare the tor_cmdline_mode_t enumeration
 **/

#ifndef TOR_CMDLINE_MODE_H
#define TOR_CMDLINE_MODE_H

/**
 * Enumeration to describe which command Tor is running.  These commands
 * are controlled by command-line options.
 **/
typedef enum {
  CMD_RUN_TOR=0, /**< The default: run Tor as a daemon. */
  CMD_LIST_FINGERPRINT, /**< Running --list-fingerprint. */
  CMD_HASH_PASSWORD, /**< Running --hash-password. */
  CMD_VERIFY_CONFIG, /**< Running --verify-config. */
  CMD_DUMP_CONFIG, /**< Running --dump-config. */
  CMD_KEYGEN, /**< Running --keygen */
  CMD_KEY_EXPIRATION, /**< Running --key-expiration */
  CMD_IMMEDIATE, /**< Special value: indicates a command that is handled
                  * immediately during configuration processing. */
  CMD_RUN_UNITTESTS, /**< Special value: indicates that we have entered
                      * the Tor code from the unit tests, not from the
                      * regular Tor binary at all. */
} tor_cmdline_mode_t;

#endif /* !defined(TOR_CMDLINE_MODE_H) */
