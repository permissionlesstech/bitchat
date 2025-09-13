/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_periodic.h
 * @brief Header for feature/relay/relay_periodic.c
 **/

#ifndef TOR_FEATURE_RELAY_RELAY_PERIODIC_H
#define TOR_FEATURE_RELAY_RELAY_PERIODIC_H

#ifdef HAVE_MODULE_RELAY

void relay_register_periodic_events(void);
void reschedule_descriptor_update_check(void);

#else /* !defined(HAVE_MODULE_RELAY) */

#include "lib/cc/compat_compiler.h"

#define relay_register_periodic_events() \
  STMT_NIL
#define reschedule_descriptor_update_check() \
  STMT_NIL

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_FEATURE_RELAY_RELAY_PERIODIC_H) */
