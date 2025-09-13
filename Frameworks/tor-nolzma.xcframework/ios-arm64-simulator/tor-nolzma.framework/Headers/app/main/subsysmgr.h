/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file subsysmgr.h
 * @brief Header for subsysmgr.c
 **/

#ifndef TOR_SUBSYSMGR_T
#define TOR_SUBSYSMGR_T

#include "lib/subsys/subsys.h"

extern const struct subsys_fns_t *tor_subsystems[];
extern const unsigned n_tor_subsystems;

int subsystems_init(void);
int subsystems_init_upto(int level);

struct pubsub_builder_t;
int subsystems_add_pubsub_upto(struct pubsub_builder_t *builder,
                               int target_level);
int subsystems_add_pubsub(struct pubsub_builder_t *builder);

void subsystems_shutdown(void);
void subsystems_shutdown_downto(int level);

void subsystems_prefork(void);
void subsystems_postfork(void);
void subsystems_thread_cleanup(void);

void subsystems_dump_list(void);

struct config_mgr_t;
int subsystems_register_options_formats(struct config_mgr_t *mgr);
int subsystems_register_state_formats(struct config_mgr_t *mgr);
struct or_options_t;
struct or_state_t;
int subsystems_set_options(const struct config_mgr_t *mgr,
                           struct or_options_t *options);
int subsystems_set_state(const struct config_mgr_t *mgr,
                         struct or_state_t *state);
int subsystems_flush_state(const struct config_mgr_t *mgr,
                           struct or_state_t *state);

#ifdef TOR_UNIT_TESTS
int subsystems_get_options_idx(const subsys_fns_t *sys);
int subsystems_get_state_idx(const subsys_fns_t *sys);
#endif

#endif /* !defined(TOR_SUBSYSMGR_T) */
