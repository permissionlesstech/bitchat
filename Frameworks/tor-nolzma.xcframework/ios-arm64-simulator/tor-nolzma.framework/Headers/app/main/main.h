/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file main.h
 * \brief Header file for main.c.
 **/

#ifndef TOR_MAIN_H
#define TOR_MAIN_H

void handle_signals(void);
void activate_signal(int signal_num);

int try_locking(const or_options_t *options, int err_if_locked);
int have_lockfile(void);
void release_lockfile(void);

void tor_remove_file(const char *filename);

int tor_init(int argc, char **argv);

int run_tor_main_loop(void);

void pubsub_install(void);
void pubsub_connect(void);

#endif /* !defined(TOR_MAIN_H) */
