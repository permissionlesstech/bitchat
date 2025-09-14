/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file signing.h
 * \brief Header file for signing.c.
 **/

#ifndef TOR_SIGNING_H
#define TOR_SIGNING_H

#define DIROBJ_MAX_SIG_LEN 256
char *router_get_dirobj_signature(const char *digest,
                                  size_t digest_len,
                                  const crypto_pk_t *private_key);
int router_append_dirobj_signature(char *buf, size_t buf_len,
                                   const char *digest,
                                   size_t digest_len,
                                   crypto_pk_t *private_key);
#endif /* !defined(TOR_SIGNING_H) */
