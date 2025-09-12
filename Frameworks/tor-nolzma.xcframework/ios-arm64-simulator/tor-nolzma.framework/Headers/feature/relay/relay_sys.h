/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_sys.h
 * @brief Header for feature/relay/relay_sys.c
 **/

#ifndef TOR_FEATURE_RELAY_RELAY_SYS_H
#define TOR_FEATURE_RELAY_RELAY_SYS_H

extern const struct subsys_fns_t sys_relay;

/**
 * Subsystem level for the relay system.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define RELAY_SUBSYS_LEVEL 50

#endif /* !defined(TOR_FEATURE_RELAY_RELAY_SYS_H) */
