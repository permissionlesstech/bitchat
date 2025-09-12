/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file buffers_net.h
 *
 * \brief Header file for buffers_net.c.
 **/

#ifndef TOR_BUFFERS_NET_H
#define TOR_BUFFERS_NET_H

#include <stddef.h>
#include "lib/net/socket.h"

struct buf_t;
int buf_read_from_socket(struct buf_t *buf, tor_socket_t s, size_t at_most,
                         int *reached_eof,
                         int *socket_error);

int buf_flush_to_socket(struct buf_t *buf, tor_socket_t s, size_t sz);

int buf_read_from_pipe(struct buf_t *buf, int fd, size_t at_most,
                       int *reached_eof,
                       int *socket_error);

int buf_flush_to_pipe(struct buf_t *buf, int fd, size_t sz);

#endif /* !defined(TOR_BUFFERS_NET_H) */
