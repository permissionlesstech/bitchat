/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file server_port_cfg_st.h
 * @brief Configuration structure for server ports.
 **/

#ifndef SERVER_PORT_CFG_ST_H
#define SERVER_PORT_CFG_ST_H

struct server_port_cfg_t {
  /* Server port types (or, dir) only: */
  unsigned int no_advertise : 1;
  unsigned int no_listen : 1;
  unsigned int all_addrs : 1;
  unsigned int bind_ipv4_only : 1;
  unsigned int bind_ipv6_only : 1;
};

#endif /* !defined(SERVER_PORT_CFG_ST_H) */
