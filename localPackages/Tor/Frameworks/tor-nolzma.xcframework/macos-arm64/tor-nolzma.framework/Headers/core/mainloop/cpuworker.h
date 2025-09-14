/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2024, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file cpuworker.h
 * \brief Header file for cpuworker.c.
 **/

#ifndef TOR_CPUWORKER_H
#define TOR_CPUWORKER_H

int cpuworker_init(void);
void cpuworker_free_all(void);
void cpuworkers_rotate_keyinfo(void);

void cpuworker_consensus_has_changed(const networkstatus_t *ns);

struct workqueue_entry_t;
enum workqueue_reply_t;
enum workqueue_priority_t;
MOCK_DECL(struct workqueue_entry_t *, cpuworker_queue_work, (
                    enum workqueue_priority_t priority,
                    enum workqueue_reply_t (*fn)(void *, void *),
                    void (*reply_fn)(void *),
                    void *arg));

struct create_cell_t;
int assign_onionskin_to_cpuworker(or_circuit_t *circ,
                                  struct create_cell_t *onionskin);

uint64_t estimated_usec_for_onionskins(uint32_t n_requests,
                                       uint16_t onionskin_type);
void cpuworker_log_onionskin_overhead(int severity, int onionskin_type,
                                      const char *onionskin_type_name);
void cpuworker_cancel_circ_handshake(or_circuit_t *circ);

unsigned int cpuworker_get_n_threads(void);

#endif /* !defined(TOR_CPUWORKER_H) */

