/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file lockfile.h
 *
 * \brief Header for lockfile.c
 **/

#ifndef TOR_LOCKFILE_H
#define TOR_LOCKFILE_H

typedef struct tor_lockfile_t tor_lockfile_t;
tor_lockfile_t *tor_lockfile_lock(const char *filename, int blocking,
                                  int *locked_out);
void tor_lockfile_unlock(tor_lockfile_t *lockfile);

#endif /* !defined(TOR_LOCKFILE_H) */
