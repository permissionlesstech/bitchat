/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file proto_http.h
 * @brief Header for proto_http.c
 **/

#ifndef TOR_PROTO_HTTP_H
#define TOR_PROTO_HTTP_H

struct buf_t;

int fetch_from_buf_http(struct buf_t *buf,
                        char **headers_out, size_t max_headerlen,
                        char **body_out, size_t *body_used, size_t max_bodylen,
                        int force_complete);
int peek_buf_has_http_command(const struct buf_t *buf);

#ifdef PROTO_HTTP_PRIVATE
STATIC int buf_http_find_content_length(const char *headers, size_t headerlen,
                                        size_t *result_out);
#endif

#endif /* !defined(TOR_PROTO_HTTP_H) */
