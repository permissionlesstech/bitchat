/* Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file qstring.h
 * \brief Header for qstring.c
 */

#ifndef TOR_ENCODING_QSTRING_H
#define TOR_ENCODING_QSTRING_H

#include <stddef.h>

const char *decode_qstring(const char *start, size_t in_len_max,
                           char **out, size_t *out_len);

#endif /* !defined(TOR_ENCODING_QSTRING_H) */
