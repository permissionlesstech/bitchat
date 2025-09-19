/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file control_connection_st.h
 * @brief Controller connection structure.
 **/

#ifndef CONTROL_CONNECTION_ST_H
#define CONTROL_CONNECTION_ST_H

#include "core/or/or.h"
#include "core/or/connection_st.h"

/** Subtype of connection_t for an connection to a controller. */
struct control_connection_t {
  connection_t base_;

  uint64_t event_mask; /**< Bitfield: which events does this controller
                        * care about?
                        * EVENT_MAX_ is >31, so we need a 64 bit mask */

  /** True if we have sent a protocolinfo reply on this connection. */
  unsigned int have_sent_protocolinfo:1;
  /** True if we have received a takeownership command on this
   * connection. */
  unsigned int is_owning_control_connection:1;

  /** List of ephemeral onion services belonging to this connection. */
  smartlist_t *ephemeral_onion_services;

  /** If we have sent an AUTHCHALLENGE reply on this connection and
   * have not received a successful AUTHENTICATE command, points to
   * the value which the client must send to authenticate itself;
   * otherwise, NULL. */
  char *safecookie_client_hash;

  /** Amount of space allocated in incoming_cmd. */
  uint32_t incoming_cmd_len;
  /** Number of bytes currently stored in incoming_cmd. */
  uint32_t incoming_cmd_cur_len;
  /** A control command that we're reading from the inbuf, but which has not
   * yet arrived completely. */
  char *incoming_cmd;
  /** The control command that we are currently processing. */
  char *current_cmd;
};

#endif /* !defined(CONTROL_CONNECTION_ST_H) */
