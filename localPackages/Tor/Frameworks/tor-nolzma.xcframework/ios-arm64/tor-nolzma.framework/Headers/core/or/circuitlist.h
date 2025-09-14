/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitlist.h
 * \brief Header file for circuitlist.c.
 **/

#ifndef TOR_CIRCUITLIST_H
#define TOR_CIRCUITLIST_H

#include "lib/container/handles.h"
#include "lib/testsupport/testsupport.h"
#include "feature/hs/hs_ident.h"
#include "core/or/ocirc_event.h"

/** Circuit state: I'm the origin, still haven't done all my handshakes. */
#define CIRCUIT_STATE_BUILDING 0
/** Circuit state: Waiting to process the onionskin. */
#define CIRCUIT_STATE_ONIONSKIN_PENDING 1
/** Circuit state: I'd like to deliver a create, but my n_chan is still
 * connecting. */
#define CIRCUIT_STATE_CHAN_WAIT 2
/** Circuit state: the circuit is open but we don't want to actually use it
 * until we find out if a better guard will be available.
 */
#define CIRCUIT_STATE_GUARD_WAIT 3
/** Circuit state: onionskin(s) processed, ready to send/receive cells. */
#define CIRCUIT_STATE_OPEN 4

#define CIRCUIT_PURPOSE_MIN_ 1

/* these circuits were initiated elsewhere */
#define CIRCUIT_PURPOSE_OR_MIN_ 1
/** OR-side circuit purpose: normal circuit, at OR. */
#define CIRCUIT_PURPOSE_OR 1
/** OR-side circuit purpose: At OR, from the service, waiting for intro from
 * clients. */
#define CIRCUIT_PURPOSE_INTRO_POINT 2
/** OR-side circuit purpose: At OR, from the client, waiting for the service.
 */
#define CIRCUIT_PURPOSE_REND_POINT_WAITING 3
/** OR-side circuit purpose: At OR, both circuits have this purpose. */
#define CIRCUIT_PURPOSE_REND_ESTABLISHED 4
#define CIRCUIT_PURPOSE_OR_MAX_ 4

/* these circuits originate at this node */

/* here's how circ client-side purposes work:
 *   normal circuits are C_GENERAL.
 *   circuits that are c_introducing are either on their way to
 *     becoming open, or they are open and waiting for a
 *     suitable rendcirc before they send the intro.
 *   circuits that are c_introduce_ack_wait have sent the intro,
 *     but haven't gotten a response yet.
 *   circuits that are c_establish_rend are either on their way
 *     to becoming open, or they are open and have sent the
 *     establish_rendezvous cell but haven't received an ack.
 *   circuits that are c_rend_ready are open and have received a
 *     rend ack, but haven't heard from the service yet.
 *   circuits that are c_rend_ready_intro_acked are open, and
 *     some intro circ has sent its intro and received an ack.
 *   circuits that are c_rend_joined are open, have heard from
 *     the service, and are talking to it.
 */
/** Client-side circuit purpose: Normal circuit, with cpath. */
#define CIRCUIT_PURPOSE_C_GENERAL 5
#define CIRCUIT_PURPOSE_C_HS_MIN_ 6
/** Client-side circuit purpose: at the client, connecting to intro point. */
#define CIRCUIT_PURPOSE_C_INTRODUCING 6
/** Client-side circuit purpose: at the client, sent INTRODUCE1 to intro point,
 * waiting for ACK/NAK. */
#define CIRCUIT_PURPOSE_C_INTRODUCE_ACK_WAIT 7
/** Client-side circuit purpose: at the client, introduced and acked, closing.
 */
#define CIRCUIT_PURPOSE_C_INTRODUCE_ACKED 8
/** Client-side circuit purpose: at the client, waiting for ack. */
#define CIRCUIT_PURPOSE_C_ESTABLISH_REND 9
/** Client-side circuit purpose: at the client, waiting for the service. */
#define CIRCUIT_PURPOSE_C_REND_READY 10
/** Client-side circuit purpose: at the client, waiting for the service,
 * INTRODUCE has been acknowledged. */
#define CIRCUIT_PURPOSE_C_REND_READY_INTRO_ACKED 11
/** Client-side circuit purpose: at the client, rendezvous established. */
#define CIRCUIT_PURPOSE_C_REND_JOINED 12
/** This circuit is used for getting hsdirs */
#define CIRCUIT_PURPOSE_C_HSDIR_GET 13
#define CIRCUIT_PURPOSE_C_HS_MAX_ 13
/** This circuit is used for build time measurement only */
#define CIRCUIT_PURPOSE_C_MEASURE_TIMEOUT 14
/** This circuit is being held open by circuit padding */
#define CIRCUIT_PURPOSE_C_CIRCUIT_PADDING 15
#define CIRCUIT_PURPOSE_C_MAX_ 15

#define CIRCUIT_PURPOSE_S_HS_MIN_ 16
/** Hidden-service-side circuit purpose: at the service, waiting for
 * introductions. */
#define CIRCUIT_PURPOSE_S_ESTABLISH_INTRO 16
/** Hidden-service-side circuit purpose: at the service, successfully
 * established intro. */
#define CIRCUIT_PURPOSE_S_INTRO 17
/** Hidden-service-side circuit purpose: at the service, connecting to rend
 * point. */
#define CIRCUIT_PURPOSE_S_CONNECT_REND 18
/** Hidden-service-side circuit purpose: at the service, rendezvous
 * established. */
#define CIRCUIT_PURPOSE_S_REND_JOINED 19
/** This circuit is used for uploading hsdirs */
#define CIRCUIT_PURPOSE_S_HSDIR_POST 20
#define CIRCUIT_PURPOSE_S_HS_MAX_ 20

/** A testing circuit; not meant to be used for actual traffic. It is used for
 * bandwidth measurement, reachability test and address discovery from an
 * authority using the NETINFO cell. */
#define CIRCUIT_PURPOSE_TESTING 21
/** A controller made this circuit and Tor should not cannibalize it or attach
 * streams to it without explicitly being told. */
#define CIRCUIT_PURPOSE_CONTROLLER 22
/** This circuit is used for path bias probing only */
#define CIRCUIT_PURPOSE_PATH_BIAS_TESTING 23

/** This circuit is used for vanguards/restricted paths.
 *
 *  This type of circuit is *only* created preemptively and never
 *  on-demand. When an HS operation needs to take place (e.g. connect to an
 *  intro point), these circuits are then cannibalized and repurposed to the
 *  actual needed HS purpose. */
#define CIRCUIT_PURPOSE_HS_VANGUARDS 24

/**
 * These two purposes are for conflux. The first is for circuits that are
 * being built, but not yet linked. The second is for circuits that are
 * linked and ready to use for streams. */
#define CIRCUIT_PURPOSE_CONFLUX_UNLINKED 25
#define CIRCUIT_PURPOSE_CONFLUX_LINKED 26

#define CIRCUIT_PURPOSE_MAX_ 26
/** A catch-all for unrecognized purposes. Currently we don't expect
 * to make or see any circuits with this purpose. */
#define CIRCUIT_PURPOSE_UNKNOWN 255

/** True iff the circuit purpose <b>p</b> is for a circuit that
 * originated at this node. */
#define CIRCUIT_PURPOSE_IS_ORIGIN(p) ((p)>CIRCUIT_PURPOSE_OR_MAX_)
/** True iff the circuit purpose <b>p</b> is for a circuit that originated
 * here to serve as a client.  (Hidden services don't count here.) */
#define CIRCUIT_PURPOSE_IS_CLIENT(p)  \
  ((p)> CIRCUIT_PURPOSE_OR_MAX_ &&    \
   (p)<=CIRCUIT_PURPOSE_C_MAX_)
/** True iff the circuit_t <b>c</b> is actually an origin_circuit_t. */
#define CIRCUIT_IS_ORIGIN(c) (CIRCUIT_PURPOSE_IS_ORIGIN((c)->purpose))
/** True iff the circuit purpose <b>p</b> is for an established rendezvous
 * circuit. */
#define CIRCUIT_PURPOSE_IS_ESTABLISHED_REND(p) \
  ((p) == CIRCUIT_PURPOSE_C_REND_JOINED ||     \
   (p) == CIRCUIT_PURPOSE_S_REND_JOINED)
/** True iff the circuit_t c is actually an or_circuit_t */
#define CIRCUIT_IS_ORCIRC(c) (((circuit_t *)(c))->magic == OR_CIRCUIT_MAGIC)

/** True iff this circuit purpose should count towards the global
 * pending rate limit (set by MaxClientCircuitsPending). We count all
 * general purpose circuits, as well as the first step of client onion
 * service connections (HSDir gets). */
#define CIRCUIT_PURPOSE_COUNTS_TOWARDS_MAXPENDING(p) \
    ((p) == CIRCUIT_PURPOSE_C_GENERAL || \
     (p) == CIRCUIT_PURPOSE_C_HSDIR_GET)

/** Stats. */
extern double cc_stats_circ_close_cwnd_ma;
extern double cc_stats_circ_close_ss_cwnd_ma;
extern uint64_t cc_stats_circs_closed;

/** Convert a circuit_t* to a pointer to the enclosing or_circuit_t.  Assert
 * if the cast is impossible. */
or_circuit_t *TO_OR_CIRCUIT(circuit_t *);
const or_circuit_t *CONST_TO_OR_CIRCUIT(const circuit_t *);
/** Convert a circuit_t* to a pointer to the enclosing origin_circuit_t.
 * Assert if the cast is impossible. */
origin_circuit_t *TO_ORIGIN_CIRCUIT(circuit_t *);
const origin_circuit_t *CONST_TO_ORIGIN_CIRCUIT(const circuit_t *);

MOCK_DECL(smartlist_t *, circuit_get_global_list, (void));
smartlist_t *circuit_get_global_origin_circuit_list(void);
int circuit_any_opened_circuits(void);
int circuit_any_opened_circuits_cached(void);
void circuit_cache_opened_circuit_state(int circuits_are_opened);

const char *circuit_state_to_string(int state);
const char *circuit_purpose_to_controller_string(uint8_t purpose);
const char *circuit_purpose_to_controller_hs_state_string(uint8_t purpose);
const char *circuit_purpose_to_string(uint8_t purpose);
void circuit_dump_by_conn(connection_t *conn, int severity);
void circuit_set_p_circid_chan(or_circuit_t *circ, circid_t id,
                               channel_t *chan);
void circuit_set_n_circid_chan(circuit_t *circ, circid_t id,
                               channel_t *chan);
void channel_mark_circid_unusable(channel_t *chan, circid_t id);
void channel_mark_circid_usable(channel_t *chan, circid_t id);
time_t circuit_id_when_marked_unusable_on_channel(circid_t circ_id,
                                                  channel_t *chan);
int circuit_event_status(origin_circuit_t *circ, circuit_status_event_t tp,
                         int reason_code);
void circuit_set_state(circuit_t *circ, uint8_t state);
void circuit_close_all_marked(void);
int32_t circuit_initial_package_window(void);
origin_circuit_t *origin_circuit_new(void);
or_circuit_t *or_circuit_new(circid_t p_circ_id, channel_t *p_chan);
circuit_t *circuit_get_by_circid_channel(circid_t circ_id,
                                         channel_t *chan);
circuit_t *
circuit_get_by_circid_channel_even_if_marked(circid_t circ_id,
                                             channel_t *chan);
int circuit_id_in_use_on_channel(circid_t circ_id, channel_t *chan);
circuit_t *circuit_get_by_edge_conn(edge_connection_t *conn);
void circuit_unlink_all_from_channel(channel_t *chan, int reason);
origin_circuit_t *circuit_get_by_global_id(uint32_t id);
origin_circuit_t *circuit_get_next_by_purpose(origin_circuit_t *start,
                                              uint8_t purpose);
origin_circuit_t *circuit_get_next_intro_circ(const origin_circuit_t *start,
                                              bool want_client_circ);
origin_circuit_t *circuit_get_next_service_rp_circ(origin_circuit_t *start);
origin_circuit_t *circuit_get_next_service_hsdir_circ(origin_circuit_t *start);
origin_circuit_t *circuit_find_to_cannibalize(uint8_t purpose,
                                              extend_info_t *info, int flags);
void circuit_mark_all_unused_circs(void);
void circuit_mark_all_dirty_circs_as_unusable(void);
void circuit_synchronize_written_or_bandwidth(const circuit_t *c,
                                              circuit_channel_direction_t dir);
MOCK_DECL(void, circuit_mark_for_close_, (circuit_t *circ, int reason,
                                          int line, const char *cfile));
int circuit_get_cpath_len(origin_circuit_t *circ);
int circuit_get_cpath_opened_len(const origin_circuit_t *);
void circuit_clear_cpath(origin_circuit_t *circ);
crypt_path_t *circuit_get_cpath_hop(origin_circuit_t *circ, int hopnum);
void circuit_get_all_pending_on_channel(smartlist_t *out,
                                        channel_t *chan);
int circuit_count_pending_on_channel(channel_t *chan);

#define circuit_mark_for_close(c, reason)                               \
  circuit_mark_for_close_((c), (reason), __LINE__, SHORT_FILE__)

MOCK_DECL(void, assert_circuit_ok,(const circuit_t *c));
void circuit_free_all(void);
size_t circuits_handle_oom(size_t current_allocation);

void circuit_clear_testing_cell_stats(circuit_t *circ);

void channel_note_destroy_pending(channel_t *chan, circid_t id);
MOCK_DECL(void, channel_note_destroy_not_pending,
          (channel_t *chan, circid_t id));

smartlist_t *circuit_find_circuits_to_upgrade_from_guard_wait(void);

bool circuit_is_queue_full(const circuit_t *circ, cell_direction_t direction);

/* Declare the handle helpers */
HANDLE_DECL(circuit, circuit_t, )
#define circuit_handle_free(h)    \
    FREE_AND_NULL(circuit_handle_t, circuit_handle_free_, (h))

#ifdef CIRCUITLIST_PRIVATE
STATIC void circuit_free_(circuit_t *circ);
#define circuit_free(circ) FREE_AND_NULL(circuit_t, circuit_free_, (circ))
STATIC size_t n_cells_in_circ_queues(const circuit_t *c);
STATIC uint32_t circuit_max_queued_data_age(const circuit_t *c, uint32_t now);
STATIC uint32_t circuit_max_queued_cell_age(const circuit_t *c, uint32_t now);
STATIC uint32_t circuit_max_queued_item_age(const circuit_t *c, uint32_t now);
#endif /* defined(CIRCUITLIST_PRIVATE) */

#endif /* !defined(TOR_CIRCUITLIST_H) */
