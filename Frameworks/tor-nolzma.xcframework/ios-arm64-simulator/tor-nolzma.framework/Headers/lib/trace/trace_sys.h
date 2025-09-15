/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file log_sys.h
 * \brief Declare subsystem object for the logging module.
 **/

#ifndef TOR_TRACE_SYS_H
#define TOR_TRACE_SYS_H

extern const struct subsys_fns_t sys_tracing;

/**
 * Subsystem level for the tracing system.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define TRACE_SUBSYS_LEVEL (-85)

#endif /* !defined(TOR_TRACE_SYS_H) */
