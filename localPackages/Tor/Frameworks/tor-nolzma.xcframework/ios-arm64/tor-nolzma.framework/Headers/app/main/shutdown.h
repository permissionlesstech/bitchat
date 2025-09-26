/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file shutdown.h
 * \brief Header file for shutdown.c.
 **/

#ifndef TOR_SHUTDOWN_H
#define TOR_SHUTDOWN_H

void tor_cleanup(void);
void tor_free_all(int postfork);

#endif /* !defined(TOR_SHUTDOWN_H) */
