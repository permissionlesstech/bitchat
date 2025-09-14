/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file proto_control0.h
 * @brief Header for proto_control0.c
 **/

#ifndef TOR_PROTO_CONTROL0_H
#define TOR_PROTO_CONTROL0_H

struct buf_t;
int peek_buf_has_control0_command(struct buf_t *buf);

#endif /* !defined(TOR_PROTO_CONTROL0_H) */
