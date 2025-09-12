/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file proto_socks.h
 * @brief Header for proto_socks.c
 **/

#ifndef TOR_PROTO_SOCKS_H
#define TOR_PROTO_SOCKS_H

struct socks_request_t;
struct buf_t;

struct socks_request_t *socks_request_new(void);
void socks_request_free_(struct socks_request_t *req);
#define socks_request_free(req) \
  FREE_AND_NULL(socks_request_t, socks_request_free_, (req))
int fetch_from_buf_socks(struct buf_t *buf, socks_request_t *req,
                         int log_sockstype, int safe_socks);
int fetch_from_buf_socks_client(buf_t *buf, int state, char **reason);

#endif /* !defined(TOR_PROTO_SOCKS_H) */
