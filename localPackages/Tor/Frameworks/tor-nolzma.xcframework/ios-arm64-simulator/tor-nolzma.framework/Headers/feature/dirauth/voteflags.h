/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file voteflags.h
 * \brief Header file for voteflags.c
 **/

#ifndef TOR_VOTEFLAGS_H
#define TOR_VOTEFLAGS_H

#ifdef HAVE_MODULE_DIRAUTH
void dirserv_set_router_is_running(routerinfo_t *router, time_t now);
char *dirserv_get_flag_thresholds_line(void);
void dirserv_compute_bridge_flag_thresholds(void);
int running_long_enough_to_decide_unreachable(void);

void dirauth_set_routerstatus_from_routerinfo(routerstatus_t *rs,
                                              node_t *node,
                                              const routerinfo_t *ri,
                                              time_t now,
                                              int listbadexits,
                                              int listmiddleonly);

void dirserv_compute_performance_thresholds(digestmap_t *omit_as_sybil);
#endif /* defined(HAVE_MODULE_DIRAUTH) */

void dirserv_set_bridges_running(time_t now);

#ifdef VOTEFLAGS_PRIVATE
/** Any descriptor older than this age causes the authorities to set the
 * StaleDesc flag. */
#define DESC_IS_STALE_INTERVAL (18*60*60)
STATIC void dirserv_set_routerstatus_testing(routerstatus_t *rs);
#endif /* defined(VOTEFLAGS_PRIVATE) */

#endif /* !defined(TOR_VOTEFLAGS_H) */
