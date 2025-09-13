/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file smartlist_split.h
 * \brief Header for smartlist_split.c
 **/

#ifndef TOR_SMARTLIST_SPLIT_H
#define TOR_SMARTLIST_SPLIT_H

#define SPLIT_SKIP_SPACE   0x01
#define SPLIT_IGNORE_BLANK 0x02
#define SPLIT_STRIP_SPACE  0x04
int smartlist_split_string(smartlist_t *sl, const char *str, const char *sep,
                           int flags, int max);

#endif /* !defined(TOR_SMARTLIST_SPLIT_H) */
