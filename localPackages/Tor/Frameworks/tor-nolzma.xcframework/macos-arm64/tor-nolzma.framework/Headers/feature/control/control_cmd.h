/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control_cmd.h
 * \brief Header file for control_cmd.c.
 **/

#ifndef TOR_CONTROL_CMD_H
#define TOR_CONTROL_CMD_H

#include "lib/malloc/malloc.h"

int handle_control_command(control_connection_t *conn,
                           uint32_t cmd_data_len,
                           char *args);
void control_cmd_free_all(void);

typedef struct control_cmd_args_t control_cmd_args_t;
void control_cmd_args_free_(control_cmd_args_t *args);
void control_cmd_args_wipe(control_cmd_args_t *args);

#define control_cmd_args_free(v) \
  FREE_AND_NULL(control_cmd_args_t, control_cmd_args_free_, (v))

/**
 * Definition for the syntax of a controller command, as parsed by
 * control_cmd_parse_args.
 *
 * WORK IN PROGRESS: This structure is going to get more complex as this
 * branch goes on.
 **/
typedef struct control_cmd_syntax_t {
  /**
   * Lowest number of positional arguments that this command accepts.
   * 0 for "it's okay not to have positional arguments."
   **/
  unsigned int min_args;
  /**
   * Highest number of positional arguments that this command accepts.
   * UINT_MAX for no limit.
   **/
  unsigned int max_args;
  /**
   * If true, we should parse options after the positional arguments
   * as a set of unordered flags and key=value arguments.
   *
   * Requires that max_args is not UINT_MAX.
   **/
  bool accept_keywords;
  /**
   * If accept_keywords is true, then only the keywords listed in this
   * (NULL-terminated) array are valid keywords for this command.
   **/
  const char **allowed_keywords;
  /**
   * If accept_keywords is true, this option is passed to kvline_parse() as
   * its flags.
   **/
  unsigned kvline_flags;
  /**
   * True iff this command wants to be followed by a multiline object.
   **/
  bool want_cmddata;
  /**
   * True iff this command needs access to the raw body of the input.
   *
   * This should not be needed for pure commands; it is purely a legacy
   * option.
   **/
  bool store_raw_body;
} control_cmd_syntax_t;

#ifdef CONTROL_CMD_PRIVATE
#include "feature/hs/hs_service.h"
#include "lib/crypt_ops/crypto_ed25519.h"

/* ADD_ONION secret key to create an ephemeral service. The command supports
 * multiple versions so this union stores the key and passes it to the HS
 * subsystem depending on the requested version. */
typedef union add_onion_secret_key_t {
  /* Hidden service v3 secret key. */
  ed25519_secret_key_t *v3;
} add_onion_secret_key_t;

STATIC int add_onion_helper_keyarg(const char *arg, int discard_pk,
                                   const char **key_new_alg_out,
                                   char **key_new_blob_out,
                                   add_onion_secret_key_t *decoded_key,
                                   int *hs_version,
                                   control_connection_t *conn);

STATIC hs_service_add_ephemeral_status_t add_onion_helper_add_service(
                             int hs_version,
                             add_onion_secret_key_t *pk,
                             smartlist_t *port_cfgs, int max_streams,
                             int max_streams_close_circuit,
                             smartlist_t *auth_clients_v3, char **address_out);

STATIC control_cmd_args_t *control_cmd_parse_args(
                                   const char *command,
                                   const control_cmd_syntax_t *syntax,
                                   size_t body_len,
                                   const char *body,
                                   char **error_out);

#endif /* defined(CONTROL_CMD_PRIVATE) */

#ifdef CONTROL_MODULE_PRIVATE
smartlist_t * get_detached_onion_services(void);
#endif /* defined(CONTROL_MODULE_PRIVATE) */

#endif /* !defined(TOR_CONTROL_CMD_H) */
