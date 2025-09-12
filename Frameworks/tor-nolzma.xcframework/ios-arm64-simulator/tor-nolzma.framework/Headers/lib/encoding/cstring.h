/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file cstring.h
 *
 * \brief Header for cstring.c
 **/

#ifndef TOR_CSTRING_H
#define TOR_CSTRING_H

#include <stddef.h>
const char *unescape_string(const char *s, char **result, size_t *size_out);

#endif /* !defined(TOR_CSTRING_H) */
