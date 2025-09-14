/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dnsserv.h
 * \brief Header file for dnsserv.c.
 **/

#ifndef TOR_DNSSERV_H
#define TOR_DNSSERV_H

void dnsserv_configure_listener(connection_t *conn);
void dnsserv_close_listener(connection_t *conn);
void dnsserv_resolved(entry_connection_t *conn,
                      int answer_type,
                      size_t answer_len,
                      const char *answer,
                      int ttl);
void dnsserv_reject_request(entry_connection_t *conn);
int dnsserv_launch_request(const char *name, int is_reverse,
                           control_connection_t *control_conn);

#endif /* !defined(TOR_DNSSERV_H) */

