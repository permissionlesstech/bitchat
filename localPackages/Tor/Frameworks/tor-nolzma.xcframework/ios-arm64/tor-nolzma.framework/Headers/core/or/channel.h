/* * Copyright (c) 2012-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file channel.h
 * \brief Header file for channel.c
 **/

#ifndef TOR_CHANNEL_H
#define TOR_CHANNEL_H

#include "core/or/or.h"
#include "core/or/circuitmux.h"
#include "lib/container/handles.h"
#include "lib/crypt_ops/crypto_ed25519.h"

#include "ext/ht.h"
#include "tor_queue.h"

#define tor_timer_t timeout
struct tor_timer_t;

/* Channel handler function pointer typedefs */
typedef void (*channel_listener_fn_ptr)(channel_listener_t *, channel_t *);
typedef void (*channel_cell_handler_fn_ptr)(channel_t *, cell_t *);

/**
 * This enum is used by channelpadding to decide when to pad channels.
 * Don't add values to it without updating the checks in
 * channelpadding_decide_to_pad_channel().
 */
typedef enum {
    CHANNEL_USED_NOT_USED_FOR_FULL_CIRCS = 0,
    CHANNEL_USED_FOR_FULL_CIRCS,
    CHANNEL_USED_FOR_USER_TRAFFIC,
} channel_usage_info_t;

/** Possible rules for generating circuit IDs on an OR connection. */
typedef enum {
  CIRC_ID_TYPE_LOWER=0, /**< Pick from 0..1<<15-1. */
  CIRC_ID_TYPE_HIGHER=1, /**< Pick from 1<<15..1<<16-1. */
  /** The other side of a connection is an OP: never create circuits to it,
   * and let it use any circuit ID it wants. */
  CIRC_ID_TYPE_NEITHER=2
} circ_id_type_t;
#define circ_id_type_bitfield_t ENUM_BF(circ_id_type_t)

/* channel states for channel_t */

typedef enum {
  /**
   * Closed state - channel is inactive
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_CLOSING
   * Permitted transitions to:
   *   - CHANNEL_STATE_OPENING
   */
  CHANNEL_STATE_CLOSED = 0,
  /**
   * Opening state - channel is trying to connect
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_CLOSED
   * Permitted transitions to:
   *   - CHANNEL_STATE_CLOSING
   *   - CHANNEL_STATE_ERROR
   *   - CHANNEL_STATE_OPEN
   */
  CHANNEL_STATE_OPENING,
  /**
   * Open state - channel is active and ready for use
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_MAINT
   *   - CHANNEL_STATE_OPENING
   * Permitted transitions to:
   *   - CHANNEL_STATE_CLOSING
   *   - CHANNEL_STATE_ERROR
   *   - CHANNEL_STATE_MAINT
   */
  CHANNEL_STATE_OPEN,
  /**
   * Maintenance state - channel is temporarily offline for subclass specific
   *   maintenance activities such as TLS renegotiation.
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_OPEN
   * Permitted transitions to:
   *   - CHANNEL_STATE_CLOSING
   *   - CHANNEL_STATE_ERROR
   *   - CHANNEL_STATE_OPEN
   */
  CHANNEL_STATE_MAINT,
  /**
   * Closing state - channel is shutting down
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_MAINT
   *   - CHANNEL_STATE_OPEN
   * Permitted transitions to:
   *   - CHANNEL_STATE_CLOSED,
   *   - CHANNEL_STATE_ERROR
   */
  CHANNEL_STATE_CLOSING,
  /**
   * Error state - channel has experienced a permanent error
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_CLOSING
   *   - CHANNEL_STATE_MAINT
   *   - CHANNEL_STATE_OPENING
   *   - CHANNEL_STATE_OPEN
   * Permitted transitions to:
   *   - None
   */
  CHANNEL_STATE_ERROR,
  /**
   * Placeholder for maximum state value
   */
  CHANNEL_STATE_LAST
} channel_state_t;

/* channel listener states for channel_listener_t */

typedef enum {
  /**
   * Closed state - channel listener is inactive
   *
   * Permitted transitions from:
   *   - CHANNEL_LISTENER_STATE_CLOSING
   * Permitted transitions to:
   *   - CHANNEL_LISTENER_STATE_LISTENING
   */
  CHANNEL_LISTENER_STATE_CLOSED = 0,
  /**
   * Listening state - channel listener is listening for incoming
   * connections
   *
   * Permitted transitions from:
   *   - CHANNEL_LISTENER_STATE_CLOSED
   * Permitted transitions to:
   *   - CHANNEL_LISTENER_STATE_CLOSING
   *   - CHANNEL_LISTENER_STATE_ERROR
   */
  CHANNEL_LISTENER_STATE_LISTENING,
  /**
   * Closing state - channel listener is shutting down
   *
   * Permitted transitions from:
   *   - CHANNEL_LISTENER_STATE_LISTENING
   * Permitted transitions to:
   *   - CHANNEL_LISTENER_STATE_CLOSED,
   *   - CHANNEL_LISTENER_STATE_ERROR
   */
  CHANNEL_LISTENER_STATE_CLOSING,
  /**
   * Error state - channel listener has experienced a permanent error
   *
   * Permitted transitions from:
   *   - CHANNEL_STATE_CLOSING
   *   - CHANNEL_STATE_LISTENING
   * Permitted transitions to:
   *   - None
   */
  CHANNEL_LISTENER_STATE_ERROR,
  /**
   * Placeholder for maximum state value
   */
  CHANNEL_LISTENER_STATE_LAST
} channel_listener_state_t;

/**
 * Channel struct; see the channel_t typedef in or.h.  A channel is an
 * abstract interface for the OR-to-OR connection, similar to connection_or_t,
 * but without the strong coupling to the underlying TLS implementation.  They
 * are constructed by calling a protocol-specific function to open a channel
 * to a particular node, and once constructed support the abstract operations
 * defined below.
 */
struct channel_t {
  /** Magic number for type-checking cast macros */
  uint32_t magic;

  /** List entry for hashtable for global-identifier lookup. */
  HT_ENTRY(channel_t) gidmap_node;

  /** Handle entry for handle-based lookup */
  HANDLE_ENTRY(channel, channel_t);

  /** Current channel state */
  channel_state_t state;

  /** Globally unique ID number for a channel over the lifetime of a Tor
   * process.  This may not be 0.
   */
  uint64_t global_identifier;

  /** Should we expect to see this channel in the channel lists? */
  unsigned char registered:1;

  /** has this channel ever been open? */
  unsigned int has_been_open:1;

  /**
   * This field indicates if the other side has enabled or disabled
   * padding via either the link protocol version or
   * channelpadding_negotiate cells.
   *
   * Clients can override this with ConnectionPadding in torrc to
   * disable or force padding to relays, but relays cannot override the
   * client's request.
   */
  unsigned int padding_enabled:1;

  /** Cached value of our decision to pad (to avoid expensive
   * checks during critical path statistics counting). */
  unsigned int currently_padding:1;

  /** Is there a pending netflow padding callback? */
  unsigned int pending_padding_callback:1;

  /** Is our peer likely to consider this channel canonical? */
  unsigned int is_canonical_to_peer:1;

  /** Has this channel ever been used for non-directory traffic?
   * Used to decide what channels to pad, and when. */
  channel_usage_info_t channel_usage;

  /** When should we send a cell for netflow padding? 0 means no padding is
   *  scheduled. */
  monotime_coarse_t next_padding_time;

  /** The callback pointer for the padding callbacks */
  struct tor_timer_t *padding_timer;
  /** The handle to this channel (to free on canceled timers) */
  struct channel_handle_t *timer_handle;

  /** If not UNSPEC, the address that the peer says we have. */
  tor_addr_t addr_according_to_peer;

  /**
   * These two fields specify the minimum and maximum negotiated timeout
   * values for inactivity (send or receive) before we decide to pad a
   * channel. These fields can be set either via a PADDING_NEGOTIATE cell,
   * or the torrc option ReducedConnectionPadding. The consensus parameters
   * nf_ito_low and nf_ito_high are used to ensure that padding can only be
   * negotiated to be less frequent than what is specified in the consensus.
   * (This is done to prevent wingnut clients from requesting excessive
   * padding).
   *
   * The actual timeout value is randomly chosen between these two values
   * as per the table in channelpadding_get_netflow_inactive_timeout_ms(),
   * after ensuring that these values do not specify lower timeouts than
   * the consensus parameters.
   *
   * If these are 0, we have not negotiated or specified custom padding
   * times, and instead use consensus defaults. */
  uint16_t padding_timeout_low_ms;
  uint16_t padding_timeout_high_ms;

  /** Why did we close?
   */
  enum {
    CHANNEL_NOT_CLOSING = 0,
    CHANNEL_CLOSE_REQUESTED,
    CHANNEL_CLOSE_FROM_BELOW,
    CHANNEL_CLOSE_FOR_ERROR
  } reason_for_closing;

  /** State variable for use by the scheduler */
  enum {
    /**
     * The channel is not open, or it has a full output buffer but no queued
     * cells.
     */
    SCHED_CHAN_IDLE = 0,
    /**
     * The channel has space on its output buffer to write, but no queued
     * cells.
     */
    SCHED_CHAN_WAITING_FOR_CELLS,
    /**
     * The scheduler has queued cells but no output buffer space to write.
     */
    SCHED_CHAN_WAITING_TO_WRITE,
    /**
     * The scheduler has both queued cells and output buffer space, and is
     * eligible for the scheduler loop.
     */
    SCHED_CHAN_PENDING
  } scheduler_state;

  /** Heap index for use by the scheduler */
  int sched_heap_idx;

  /** Timestamps for both cell channels and listeners */
  time_t timestamp_created; /* Channel created */
  time_t timestamp_active; /* Any activity */

  /**
   * This is a monotonic timestamp that marks when we
   * believe the channel has actually sent or received data to/from
   * the wire. Right now, it is used to determine when we should send
   * a padding cell for channelpadding.
   *
   * XXX: Are we setting timestamp_xfer_ms in the right places to
   * accurately reflect actual network data transfer? Or might this be
   * very wrong wrt when bytes actually go on the wire?
   */
  monotime_coarse_t timestamp_xfer;

  /* Methods implemented by the lower layer */

  /** Free a channel */
  void (*free_fn)(channel_t *);
  /** Close an open channel */
  void (*close)(channel_t *);
  /** Describe the transport subclass for this channel */
  const char * (*describe_transport)(channel_t *);
  /** Optional method to dump transport-specific statistics on the channel */
  void (*dumpstats)(channel_t *, int);

  /** Registered handlers for incoming cells */
  channel_cell_handler_fn_ptr cell_handler;

  /* Methods implemented by the lower layer */

  /**
   * Ask the lower layer for an estimate of the average overhead for
   * transmissions on this channel.
   */
  double (*get_overhead_estimate)(channel_t *);
  /*
   * Ask the underlying transport what the remote endpoint address is, in a
   * tor_addr_t.  Write the address out to the provided tor_addr_t *, and
   * return 1 if successful or 0 if no address available.
   */
  int (*get_remote_addr)(const channel_t *, tor_addr_t *);
  int (*get_transport_name)(channel_t *chan, char **transport_out);

  /**
   * Get a human-readable text description of the remote endpoint, for
   * logging.
   */
  const char * (*describe_peer)(const channel_t *);
  /** Check if the lower layer has queued writes */
  int (*has_queued_writes)(channel_t *);
  /**
   * Ask the lower layer if this is 'canonical', for a transport-specific
   * definition of canonical.
   */
  int (*is_canonical)(channel_t *);
  /** Check if this channel matches a specified extend_info_t */
  int (*matches_extend_info)(channel_t *, extend_info_t *);
  /** Check if this channel matches a target address when extending */
  int (*matches_target)(channel_t *, const tor_addr_t *);
  /* Ask the lower layer how many bytes it has queued but not yet sent */
  size_t (*num_bytes_queued)(channel_t *);
  /* Ask the lower layer how many cells can be written */
  int (*num_cells_writeable)(channel_t *);
  /* Write a cell to an open channel */
  int (*write_cell)(channel_t *, cell_t *);
  /** Write a packed cell to an open channel */
  int (*write_packed_cell)(channel_t *, packed_cell_t *);
  /** Write a variable-length cell to an open channel */
  int (*write_var_cell)(channel_t *, var_cell_t *);

  /**
   * Hash of the public RSA key for the other side's RSA identity key -- or
   * zeroes if we don't have an RSA identity in mind for the other side, and
   * it hasn't shown us one.
   *
   * Note that this is the RSA identity that we hope the other side has -- not
   * necessarily its true identity.  Don't believe this identity unless
   * authentication has happened.
   */
  char identity_digest[DIGEST_LEN];
  /**
   * Ed25519 key for the other side of this channel -- or zeroes if we don't
   * have an Ed25519 identity in mind for the other side, and it hasn't shown
   * us one.
   *
   * Note that this is the identity that we hope the other side has -- not
   * necessarily its true identity.  Don't believe this identity unless
   * authentication has happened.
   */
  struct ed25519_public_key_t ed25519_identity;

  /**
   * Linked list of channels with the same RSA identity digest, for use with
   * the digest->channel map
   */
  TOR_LIST_ENTRY(channel_t) next_with_same_id;

  /** Circuit mux for circuits sending on this channel */
  circuitmux_t *cmux;

  /** Circuit ID generation stuff for use by circuitbuild.c */

  /**
   * When we send CREATE cells along this connection, which half of the
   * space should we use?
   */
  circ_id_type_bitfield_t circ_id_type:2;
  /* DOCDOC */
  unsigned wide_circ_ids:1;

  /** For how many circuits are we n_chan?  What about p_chan? */
  unsigned int num_n_circuits, num_p_circuits;

  /**
   * True iff this channel shouldn't get any new circs attached to it,
   * because the connection is too old, or because there's a better one.
   * More generally, this flag is used to note an unhealthy connection;
   * for example, if a bad connection fails we shouldn't assume that the
   * router itself has a problem.
   */
  unsigned int is_bad_for_new_circs:1;

  /** True iff we have decided that the other end of this connection
   * is a client or bridge relay.  Connections with this flag set should never
   * be used to satisfy an EXTEND request. */
  unsigned int is_client:1;

  /** Set if the channel was initiated remotely (came from a listener) */
  unsigned int is_incoming:1;

  /** Set by lower layer if this is local; i.e., everything it communicates
   * with for this channel returns true for is_local_addr().  This is used
   * to decide whether to declare reachability when we receive something on
   * this channel in circuitbuild.c
   */
  unsigned int is_local:1;

  /** Have we logged a warning about circID exhaustion on this channel?
   * If so, when? */
  ratelim_t last_warned_circ_ids_exhausted;

  /** Channel timestamps for cell channels */
  time_t timestamp_client; /*(< Client used this, according to relay.c */
  time_t timestamp_recv; /**< Cell received from lower layer */
  time_t timestamp_xmit; /**< Cell sent to lower layer */

  /** Timestamp for run_connection_housekeeping(). We update this once a
   * second when we run housekeeping and find a circuit on this channel, and
   * whenever we add a circuit to the channel. */
  time_t timestamp_last_had_circuits;

  /** Unique ID for measuring direct network status requests;vtunneled ones
   * come over a circuit_t, which has a dirreq_id field as well, but is a
   * distinct namespace. */
  uint64_t dirreq_id;

  /** Channel counters for cells and bytes we have received. */
  uint64_t n_cells_recved, n_bytes_recved;
  /** Channel counters for cells and bytes we have sent. */
  uint64_t n_cells_xmitted, n_bytes_xmitted;
};

struct channel_listener_t {
  /** Current channel listener state */
  channel_listener_state_t state;

  /** Globally unique ID number for a channel over the lifetime of a Tor
   * process.
   */
  uint64_t global_identifier;

  /** Should we expect to see this channel in the channel lists? */
  unsigned char registered:1;

  /** Why did we close?
   */
  enum {
    CHANNEL_LISTENER_NOT_CLOSING = 0,
    CHANNEL_LISTENER_CLOSE_REQUESTED,
    CHANNEL_LISTENER_CLOSE_FROM_BELOW,
    CHANNEL_LISTENER_CLOSE_FOR_ERROR
  } reason_for_closing;

  /** Timestamps for both cell channels and listeners */
  time_t timestamp_created; /* Channel created */
  time_t timestamp_active; /* Any activity */

  /* Methods implemented by the lower layer */

  /** Free a channel */
  void (*free_fn)(channel_listener_t *);
  /** Close an open channel */
  void (*close)(channel_listener_t *);
  /** Describe the transport subclass for this channel */
  const char * (*describe_transport)(channel_listener_t *);
  /** Optional method to dump transport-specific statistics on the channel */
  void (*dumpstats)(channel_listener_t *, int);

  /** Registered listen handler to call on incoming connection */
  channel_listener_fn_ptr listener;

  /** List of pending incoming connections */
  smartlist_t *incoming_list;

  /** Timestamps for listeners */
  time_t timestamp_accepted;

  /** Counters for listeners */
  uint64_t n_accepted;
};

/* Channel state manipulations */

int channel_state_is_valid(channel_state_t state);
int channel_listener_state_is_valid(channel_listener_state_t state);

int channel_state_can_transition(channel_state_t from, channel_state_t to);
int channel_listener_state_can_transition(channel_listener_state_t from,
                                          channel_listener_state_t to);

const char * channel_state_to_string(channel_state_t state);
const char *
channel_listener_state_to_string(channel_listener_state_t state);

/* Abstract channel operations */

void channel_mark_for_close(channel_t *chan);
int channel_write_packed_cell(channel_t *chan, packed_cell_t *cell);

void channel_listener_mark_for_close(channel_listener_t *chan_l);
void channel_mark_as_used_for_origin_circuit(channel_t *chan);

/* Channel callback registrations */

/* Listener callback */
void channel_listener_set_listener_fn(channel_listener_t *chan,
                                      channel_listener_fn_ptr listener);

/* Incoming cell callbacks */
channel_cell_handler_fn_ptr channel_get_cell_handler(channel_t *chan);

void channel_set_cell_handlers(channel_t *chan,
                               channel_cell_handler_fn_ptr cell_handler);

/* Clean up closed channels and channel listeners periodically; these are
 * called from run_scheduled_events() in main.c.
 */
void channel_run_cleanup(void);
void channel_listener_run_cleanup(void);

/* Close all channels and deallocate everything */
void channel_free_all(void);

/* Dump some statistics in the log */
void channel_dumpstats(int severity);
void channel_listener_dumpstats(int severity);

#ifdef CHANNEL_OBJECT_PRIVATE

#ifdef CHANNEL_FILE_PRIVATE

STATIC void channel_add_to_digest_map(channel_t *chan);
STATIC bool channel_matches_target_addr_for_extend(
                                          channel_t *chan,
                                          const tor_addr_t *target_ipv4_addr,
                                          const tor_addr_t *target_ipv6_addr);
#endif /* defined(CHANNEL_FILE_PRIVATE) */

/* Channel operations for subclasses and internal use only */

/* Initialize a newly allocated channel - do this first in subclass
 * constructors.
 */

void channel_init(channel_t *chan);
void channel_init_listener(channel_listener_t *chan);

/* Channel registration/unregistration */
void channel_register(channel_t *chan);
void channel_unregister(channel_t *chan);

/* Channel listener registration/unregistration */
void channel_listener_register(channel_listener_t *chan_l);
void channel_listener_unregister(channel_listener_t *chan_l);

/* Close from below */
void channel_close_from_lower_layer(channel_t *chan);
void channel_close_for_error(channel_t *chan);
void channel_closed(channel_t *chan);

/* Free a channel */
void channel_free_(channel_t *chan);
#define channel_free(chan) FREE_AND_NULL(channel_t, channel_free_, (chan))
void channel_listener_free_(channel_listener_t *chan_l);
#define channel_listener_free(chan_l) \
  FREE_AND_NULL(channel_listener_t, channel_listener_free_, (chan_l))

/* State/metadata setters */

void channel_change_state(channel_t *chan, channel_state_t to_state);
void channel_change_state_open(channel_t *chan);
void channel_clear_identity_digest(channel_t *chan);
void channel_clear_remote_end(channel_t *chan);
void channel_mark_local(channel_t *chan);
void channel_mark_incoming(channel_t *chan);
void channel_mark_outgoing(channel_t *chan);
void channel_mark_remote(channel_t *chan);
void channel_set_identity_digest(channel_t *chan,
                             const char *identity_digest,
                             const struct ed25519_public_key_t *ed_identity);

void channel_listener_change_state(channel_listener_t *chan_l,
                                   channel_listener_state_t to_state);

/* Timestamp updates */
void channel_timestamp_created(channel_t *chan);
void channel_timestamp_active(channel_t *chan);
void channel_timestamp_recv(channel_t *chan);
void channel_timestamp_xmit(channel_t *chan);

void channel_listener_timestamp_created(channel_listener_t *chan_l);
void channel_listener_timestamp_active(channel_listener_t *chan_l);
void channel_listener_timestamp_accepted(channel_listener_t *chan_l);

/* Incoming channel handling */
void channel_listener_process_incoming(channel_listener_t *listener);
void channel_listener_queue_incoming(channel_listener_t *listener,
                                     channel_t *incoming);

/* Incoming cell handling */
void channel_process_cell(channel_t *chan, cell_t *cell);

/* Request from lower layer for more cells if available */
MOCK_DECL(ssize_t, channel_flush_some_cells,
          (channel_t *chan, ssize_t num_cells));

/* Query if data available on this channel */
MOCK_DECL(int, channel_more_to_flush, (channel_t *chan));

/* Notify flushed outgoing for dirreq handling */
void channel_notify_flushed(channel_t *chan);

/* Handle stuff we need to do on open like notifying circuits */
void channel_do_open_actions(channel_t *chan);

#endif /* defined(CHANNEL_OBJECT_PRIVATE) */

/* Helper functions to perform operations on channels */

int channel_send_destroy(circid_t circ_id, channel_t *chan,
                         int reason);

/*
 * Outside abstract interfaces that should eventually get turned into
 * something transport/address format independent.
 */

channel_t * channel_connect(const tor_addr_t *addr, uint16_t port,
                            const char *rsa_id_digest,
                            const struct ed25519_public_key_t *ed_id);

MOCK_DECL(channel_t *, channel_get_for_extend,(
                                   const char *rsa_id_digest,
                                   const struct ed25519_public_key_t *ed_id,
                                   const tor_addr_t *target_ipv4_addr,
                                   const tor_addr_t *target_ipv6_addr,
                                   bool for_origin_circ,
                                   const char **msg_out,
                                   int *launch_out));

/* Ask which of two channels is better for circuit-extension purposes */
int channel_is_better(channel_t *a, channel_t *b);

/** Channel lookups
 */

channel_t * channel_find_by_global_id(uint64_t global_identifier);
channel_t * channel_find_by_remote_identity(const char *rsa_id_digest,
                                    const struct ed25519_public_key_t *ed_id);

/** For things returned by channel_find_by_remote_digest(), walk the list.
 * The RSA key will match for all returned elements; the Ed25519 key might not.
 */
channel_t * channel_next_with_rsa_identity(channel_t *chan);

/*
 * Helper macros to lookup state of given channel.
 */

#define CHANNEL_IS_CLOSED(chan) (channel_is_in_state((chan), \
                                 CHANNEL_STATE_CLOSED))
#define CHANNEL_IS_OPENING(chan) (channel_is_in_state((chan), \
                                  CHANNEL_STATE_OPENING))
#define CHANNEL_IS_OPEN(chan) (channel_is_in_state((chan), \
                               CHANNEL_STATE_OPEN))
#define CHANNEL_IS_MAINT(chan) (channel_is_in_state((chan), \
                                CHANNEL_STATE_MAINT))
#define CHANNEL_IS_CLOSING(chan) (channel_is_in_state((chan), \
                                  CHANNEL_STATE_CLOSING))
#define CHANNEL_IS_ERROR(chan) (channel_is_in_state((chan), \
                                CHANNEL_STATE_ERROR))

#define CHANNEL_FINISHED(chan) (CHANNEL_IS_CLOSED(chan) || \
                                CHANNEL_IS_ERROR(chan))

#define CHANNEL_CONDEMNED(chan) (CHANNEL_IS_CLOSING(chan) || \
                                 CHANNEL_FINISHED(chan))

#define CHANNEL_CAN_HANDLE_CELLS(chan) (CHANNEL_IS_OPENING(chan) || \
                                        CHANNEL_IS_OPEN(chan) || \
                                        CHANNEL_IS_MAINT(chan))

static inline int
channel_is_in_state(channel_t *chan, channel_state_t state)
{
  return chan->state == state;
}

/*
 * Metadata queries/updates
 */

const char * channel_describe_transport(channel_t *chan);
MOCK_DECL(void, channel_dump_statistics, (channel_t *chan, int severity));
void channel_dump_transport_statistics(channel_t *chan, int severity);
MOCK_DECL(int, channel_get_addr_if_possible, (const channel_t *chan,
                                              tor_addr_t *addr_out));
MOCK_DECL(const char *, channel_describe_peer,(channel_t *chan));
int channel_has_queued_writes(channel_t *chan);
int channel_is_bad_for_new_circs(channel_t *chan);
void channel_mark_bad_for_new_circs(channel_t *chan);
int channel_is_canonical(channel_t *chan);
int channel_is_client(const channel_t *chan);
int channel_is_local(channel_t *chan);
int channel_is_incoming(channel_t *chan);
int channel_is_outgoing(channel_t *chan);
void channel_mark_client(channel_t *chan);
void channel_clear_client(channel_t *chan);
int channel_matches_extend_info(channel_t *chan, extend_info_t *extend_info);
int channel_remote_identity_matches(const channel_t *chan,
                                    const char *rsa_id_digest,
                                    const ed25519_public_key_t *ed_id);
unsigned int channel_num_circuits(channel_t *chan);
MOCK_DECL(void,channel_set_circid_type,(channel_t *chan,
                                        crypto_pk_t *identity_rcvd,
                                        int consider_identity));
void channel_timestamp_client(channel_t *chan);

const char * channel_listener_describe_transport(channel_listener_t *chan_l);
void channel_listener_dump_statistics(channel_listener_t *chan_l,
                                      int severity);
void channel_listener_dump_transport_statistics(channel_listener_t *chan_l,
                                                int severity);
void channel_check_for_duplicates(void);

void channel_update_bad_for_new_circs(const char *digest, int force);

/* Flow control queries */
int channel_num_cells_writeable(channel_t *chan);

/* Timestamp queries */
time_t channel_when_created(channel_t *chan);
time_t channel_when_last_client(channel_t *chan);
time_t channel_when_last_xmit(channel_t *chan);

/* Counter queries */
int packed_cell_is_destroy(channel_t *chan,
                           const packed_cell_t *packed_cell,
                           circid_t *circid_out);

/* Declare the handle helpers */
HANDLE_DECL(channel, channel_t,)
#define channel_handle_free(h)    \
  FREE_AND_NULL(channel_handle_t, channel_handle_free_, (h))
#undef tor_timer_t

#endif /* !defined(TOR_CHANNEL_H) */
