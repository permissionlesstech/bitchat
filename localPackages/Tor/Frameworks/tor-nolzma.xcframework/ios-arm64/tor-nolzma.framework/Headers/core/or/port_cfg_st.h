/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file port_cfg_st.h
 * @brief Listener port configuration structure.
 **/

#ifndef PORT_CFG_ST_H
#define PORT_CFG_ST_H

#include "core/or/entry_port_cfg_st.h"
#include "core/or/server_port_cfg_st.h"

/** Configuration for a single port that we're listening on. */
struct port_cfg_t {
  tor_addr_t addr; /**< The actual IP to listen on, if !is_unix_addr. */
  int port; /**< The configured port, or CFG_AUTO_PORT to tell Tor to pick its
             * own port. */
  uint8_t type; /**< One of CONN_TYPE_*_LISTENER */
  unsigned is_unix_addr : 1; /**< True iff this is an AF_UNIX address. */

  unsigned is_group_writable : 1;
  unsigned is_world_writable : 1;
  unsigned relax_dirmode_check : 1;
  unsigned explicit_addr : 1; /** Indicate if address was explicitly set or
                               * we are using the default address. */

  entry_port_cfg_t entry_cfg;

  server_port_cfg_t server_cfg;

  /* Unix sockets only: */
  /** Path for an AF_UNIX address */
  char unix_addr[FLEXIBLE_ARRAY_MEMBER];
};

#endif /* !defined(PORT_CFG_ST_H) */
