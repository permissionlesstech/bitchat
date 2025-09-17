/* Copyright (c) 2023, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux_sys.h
 * \brief Header file for conflux_sys.c.
 **/

#ifndef TOR_CONFLUX_SYS_H
#define TOR_CONFLUX_SYS_H

extern const struct subsys_fns_t sys_conflux;

/**
 * Subsystem level.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define CONFLUX_SUBSYS_LEVEL (10)

#endif /* TOR_CONFLUX_SYS_H */

