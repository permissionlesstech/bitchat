/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file predict_ports.h
 * \brief Header file for predict_ports.c.
 **/

#ifndef TOR_PREDICT_PORTS_H
#define TOR_PREDICT_PORTS_H

void predicted_ports_init(void);
void rep_hist_note_used_port(time_t now, uint16_t port);
smartlist_t *rep_hist_get_predicted_ports(time_t now);
void rep_hist_remove_predicted_ports(const smartlist_t *rmv_ports);
void rep_hist_note_used_resolve(time_t now);
void rep_hist_note_used_internal(time_t now, int need_uptime,
                                 int need_capacity);
int rep_hist_get_predicted_internal(time_t now, int *need_uptime,
                                    int *need_capacity);

int any_predicted_circuits(time_t now);
int rep_hist_circbuilding_dormant(time_t now);
int predicted_ports_prediction_time_remaining(time_t now);
void predicted_ports_free_all(void);

#endif /* !defined(TOR_PREDICT_PORTS_H) */
