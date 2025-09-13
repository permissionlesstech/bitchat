/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file alertsock.h
 *
 * \brief Header for alertsock.c
 **/

#ifndef TOR_ALERTSOCK_H
#define TOR_ALERTSOCK_H

#include "orconfig.h"
#include "lib/net/nettypes.h"
#include "lib/cc/torint.h"

/** Helper type used to manage waking up the main thread while it's in
 * the libevent main loop.  Used by the work queue code. */
typedef struct alert_sockets_t {
  /* XXXX This structure needs a better name. */
  /** Socket that the main thread should listen for EV_READ events on.
   * Note that this socket may be a regular fd on a non-Windows platform.
   */
  tor_socket_t read_fd;
  /** Socket to use when alerting the main thread. */
  tor_socket_t write_fd;
  /** Function to alert the main thread */
  int (*alert_fn)(tor_socket_t write_fd);
  /** Function to make the main thread no longer alerted. */
  int (*drain_fn)(tor_socket_t read_fd);
} alert_sockets_t;

/* Flags to disable one or more alert_sockets backends. */
#define ASOCKS_NOEVENTFD2   (1u<<0)
#define ASOCKS_NOEVENTFD    (1u<<1)
#define ASOCKS_NOPIPE2      (1u<<2)
#define ASOCKS_NOPIPE       (1u<<3)
#define ASOCKS_NOSOCKETPAIR (1u<<4)

int alert_sockets_create(alert_sockets_t *socks_out, uint32_t flags);
void alert_sockets_close(alert_sockets_t *socks);

#endif /* !defined(TOR_ALERTSOCK_H) */
