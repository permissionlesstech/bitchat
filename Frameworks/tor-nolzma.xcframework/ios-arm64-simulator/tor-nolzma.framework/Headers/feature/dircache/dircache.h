/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dircache.h
 * \brief Header file for dircache.c.
 **/

#ifndef TOR_DIRCACHE_H
#define TOR_DIRCACHE_H

int directory_handle_command(dir_connection_t *conn);

#ifdef DIRCACHE_PRIVATE
MOCK_DECL(STATIC int, directory_handle_command_get,(dir_connection_t *conn,
                                                    const char *headers,
                                                    const char *req_body,
                                                    size_t req_body_len));
MOCK_DECL(STATIC int, directory_handle_command_post,(dir_connection_t *conn,
                                                     const char *headers,
                                                     const char *body,
                                                     size_t body_len));

STATIC int handle_post_hs_descriptor(const char *url, const char *body);
enum compression_level_t;
STATIC enum compression_level_t choose_compression_level(void);

struct get_handler_args_t;
STATIC int handle_get_hs_descriptor_v3(dir_connection_t *conn,
                                       const struct get_handler_args_t *args);

STATIC int parse_http_url(const char *headers, char **url);

STATIC int parse_hs_version_from_post(const char *url, const char *prefix,
                                      const char **end_pos);

STATIC unsigned parse_accept_encoding_header(const char *h);
#endif /* defined(DIRCACHE_PRIVATE) */

#endif /* !defined(TOR_DIRCACHE_H) */
