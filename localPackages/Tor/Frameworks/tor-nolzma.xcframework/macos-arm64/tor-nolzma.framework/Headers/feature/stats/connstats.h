/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file connstats.h
 * @brief Header for feature/stats/connstats.c
 **/

#ifndef TOR_FEATURE_STATS_CONNSTATS_H
#define TOR_FEATURE_STATS_CONNSTATS_H

void conn_stats_init(time_t now);
void conn_stats_note_or_conn_bytes(uint64_t conn_id, size_t num_read,
                                   size_t num_written, time_t when,
                                   bool is_ipv6);
void conn_stats_reset(time_t now);
char *conn_stats_format(time_t now);
time_t conn_stats_save(time_t now);
void conn_stats_terminate(void);
void conn_stats_free_all(void);

#endif /* !defined(TOR_FEATURE_STATS_CONNSTATS_H) */
