/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file listener_connection_st.h
 * @brief Listener connection structure.
 **/

#ifndef LISTENER_CONNECTION_ST_H
#define LISTENER_CONNECTION_ST_H

#include "core/or/connection_st.h"

/** Subtype of connection_t; used for a listener socket. */
struct listener_connection_t {
  connection_t base_;

  /** If the connection is a CONN_TYPE_AP_DNS_LISTENER, this field points
   * to the evdns_server_port it uses to listen to and answer connections. */
  struct evdns_server_port *dns_server_port;

  entry_port_cfg_t entry_cfg;

};

#endif /* !defined(LISTENER_CONNECTION_ST_H) */
