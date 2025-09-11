/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file routermode.h
 * \brief Header file for routermode.c.
 **/

#ifndef TOR_ROUTERMODE_H
#define TOR_ROUTERMODE_H

#ifdef HAVE_MODULE_RELAY

int dir_server_mode(const or_options_t *options);

MOCK_DECL(int, server_mode, (const or_options_t *options));
MOCK_DECL(int, public_server_mode, (const or_options_t *options));
MOCK_DECL(int, advertised_server_mode, (void));

void set_server_advertised(int s);

/** Is the relay module enabled? */
#define have_module_relay() (1)

#else /* !defined(HAVE_MODULE_RELAY) */

#define dir_server_mode(options) (((void)(options)),0)
#define server_mode(options) (((void)(options)),0)
#define public_server_mode(options) (((void)(options)),0)
#define advertised_server_mode() (0)

/* We shouldn't be publishing descriptors when relay mode is disabled. */
#define set_server_advertised(s) tor_assert_nonfatal(!(s))

#define have_module_relay() (0)

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_ROUTERMODE_H) */
