/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file metrics.h
 * @brief Header for feature/metrics/metrics.c
 **/

#ifndef TOR_FEATURE_METRICS_METRICS_H
#define TOR_FEATURE_METRICS_METRICS_H

#include "lib/buf/buffers.h"
#include "lib/container/smartlist.h"

#include "app/config/or_options_st.h"

#include "lib/metrics/metrics_common.h"

struct connection_t;

/* Initializer / Cleanup. */
void metrics_init(void);
void metrics_cleanup(void);

/* Accessors. */
buf_t *metrics_get_output(const metrics_format_t fmt);

/* Connection. */
int metrics_connection_process_inbuf(struct connection_t *conn);
int metrics_connection_reached_eof(struct connection_t *conn);
int metrics_connection_finished_flushing(struct connection_t *conn);

/* Configuration. */
int metrics_parse_ports(or_options_t *options, smartlist_t *ports,
                        char **err_msg_out);

#endif /* !defined(TOR_FEATURE_METRICS_METRICS_H) */
