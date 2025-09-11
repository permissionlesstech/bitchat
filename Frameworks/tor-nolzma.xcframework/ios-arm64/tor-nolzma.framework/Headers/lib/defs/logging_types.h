/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file logging_types.h
 *
 * \brief Global definition for types used by logging systems.
 **/

#ifndef TOR_LOGGING_TYPES_H
#define TOR_LOGGING_TYPES_H

/* We define this here so that it can be used both by backtrace.h and
 * log.h.
 */

/** Mask of zero or more log domains, OR'd together. */
typedef uint64_t log_domain_mask_t;

#endif /* !defined(TOR_LOGGING_TYPES_H) */
