/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file or_sys.h
 * @brief Header for core/or/or_sys.c
 **/

#ifndef TOR_CORE_OR_OR_SYS_H
#define TOR_CORE_OR_OR_SYS_H

extern const struct subsys_fns_t sys_or;

struct pubsub_connector_t;
int ocirc_add_pubsub(struct pubsub_connector_t *connector);
int orconn_add_pubsub(struct pubsub_connector_t *connector);

#endif /* !defined(TOR_CORE_OR_OR_SYS_H) */
