/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file authcert_parse.h
 * \brief Header file for authcert_parse.c.
 **/

#ifndef TOR_AUTHCERT_PARSE_H
#define TOR_AUTHCERT_PARSE_H

authority_cert_t *authority_cert_parse_from_string(const char *s,
                                                   size_t maxlen,
                                                   const char **end_of_string);

#endif /* !defined(TOR_AUTHCERT_PARSE_H) */
