/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_DISPATCH_CFG_H
#define TOR_DISPATCH_CFG_H

/**
 * @file dispatch_cfg.h
 * @brief Header for distpach_cfg.c
 **/

#include "lib/dispatch/msgtypes.h"
#include "lib/testsupport/testsupport.h"

/**
 * A "dispatch_cfg" is the configuration used to set up a dispatcher.
 * It is created and accessed with a set of dcfg_* functions, and then
 * used with dispatcher_new() to make the dispatcher.
 */
typedef struct dispatch_cfg_t dispatch_cfg_t;

dispatch_cfg_t *dcfg_new(void);

int dcfg_msg_set_type(dispatch_cfg_t *cfg, message_id_t msg,
                      msg_type_id_t type);

int dcfg_msg_set_chan(dispatch_cfg_t *cfg, message_id_t msg,
                      channel_id_t chan);

int dcfg_type_set_fns(dispatch_cfg_t *cfg, msg_type_id_t type,
                      const dispatch_typefns_t *fns);

int dcfg_add_recv(dispatch_cfg_t *cfg, message_id_t msg,
                  subsys_id_t sys, recv_fn_t fn);

/** Free a dispatch_cfg_t. */
#define dcfg_free(cfg) \
  FREE_AND_NULL(dispatch_cfg_t, dcfg_free_, (cfg))

void dcfg_free_(dispatch_cfg_t *cfg);

#ifdef DISPATCH_NEW_PRIVATE
struct smartlist_t;
STATIC int max_in_u16_sl(const struct smartlist_t *sl, int dflt);
#endif

#endif /* !defined(TOR_DISPATCH_CFG_H) */
