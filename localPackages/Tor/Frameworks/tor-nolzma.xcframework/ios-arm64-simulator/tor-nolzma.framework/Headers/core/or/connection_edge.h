/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file connection_edge.h
 * \brief Header file for connection_edge.c.
 **/

#ifndef TOR_CONNECTION_EDGE_H
#define TOR_CONNECTION_EDGE_H

#include "lib/testsupport/testsupport.h"

#include "feature/hs/hs_service.h"

edge_connection_t *TO_EDGE_CONN(connection_t *);
entry_connection_t *TO_ENTRY_CONN(connection_t *);
entry_connection_t *EDGE_TO_ENTRY_CONN(edge_connection_t *);

const edge_connection_t *CONST_TO_EDGE_CONN(const connection_t *);
const entry_connection_t *CONST_TO_ENTRY_CONN(const connection_t *);
const entry_connection_t *CONST_EDGE_TO_ENTRY_CONN(const edge_connection_t *);

#define EXIT_CONN_STATE_MIN_ 1
/** State for an exit connection: waiting for response from DNS farm. */
#define EXIT_CONN_STATE_RESOLVING 1
/** State for an exit connection: waiting for connect() to finish. */
#define EXIT_CONN_STATE_CONNECTING 2
/** State for an exit connection: open and ready to transmit data. */
#define EXIT_CONN_STATE_OPEN 3
/** State for an exit connection: waiting to be removed. */
#define EXIT_CONN_STATE_RESOLVEFAILED 4
#define EXIT_CONN_STATE_MAX_ 4

/* The AP state values must be disjoint from the EXIT state values. */
#define AP_CONN_STATE_MIN_ 5
/** State for a SOCKS connection: waiting for SOCKS request. */
#define AP_CONN_STATE_SOCKS_WAIT 5
/** State for a SOCKS connection: got a y.onion URL; waiting to receive
 * rendezvous descriptor. */
#define AP_CONN_STATE_RENDDESC_WAIT 6
/** The controller will attach this connection to a circuit; it isn't our
 * job to do so. */
#define AP_CONN_STATE_CONTROLLER_WAIT 7
/** State for a SOCKS connection: waiting for a completed circuit. */
#define AP_CONN_STATE_CIRCUIT_WAIT 8
/** State for a SOCKS connection: sent BEGIN, waiting for CONNECTED. */
#define AP_CONN_STATE_CONNECT_WAIT 9
/** State for a SOCKS connection: sent RESOLVE, waiting for RESOLVED. */
#define AP_CONN_STATE_RESOLVE_WAIT 10
/** State for a SOCKS connection: ready to send and receive. */
#define AP_CONN_STATE_OPEN 11
/** State for a transparent natd connection: waiting for original
 * destination. */
#define AP_CONN_STATE_NATD_WAIT 12
/** State for an HTTP tunnel: waiting for an HTTP CONNECT command. */
#define AP_CONN_STATE_HTTP_CONNECT_WAIT 13
#define AP_CONN_STATE_MAX_ 13

#define EXIT_PURPOSE_MIN_ 1
/** This exit stream wants to do an ordinary connect. */
#define EXIT_PURPOSE_CONNECT 1
/** This exit stream wants to do a resolve (either normal or reverse). */
#define EXIT_PURPOSE_RESOLVE 2
#define EXIT_PURPOSE_MAX_ 2

/** True iff the AP_CONN_STATE_* value <b>s</b> means that the corresponding
 * edge connection is not attached to any circuit. */
#define AP_CONN_STATE_IS_UNATTACHED(s) \
  ((s) <= AP_CONN_STATE_CIRCUIT_WAIT || (s) == AP_CONN_STATE_NATD_WAIT)

#define connection_mark_unattached_ap(conn, endreason)                  \
  connection_mark_unattached_ap_((conn), (endreason), __LINE__, SHORT_FILE__)

/** Possible return values for parse_extended_hostname. */
typedef enum hostname_type_t {
  BAD_HOSTNAME,
  EXIT_HOSTNAME,
  NORMAL_HOSTNAME,
  ONION_V3_HOSTNAME,
} hostname_type_t;

MOCK_DECL(void,connection_mark_unattached_ap_,
          (entry_connection_t *conn, int endreason,
           int line, const char *file));
int connection_edge_reached_eof(edge_connection_t *conn);
int connection_edge_process_inbuf(edge_connection_t *conn,
                                  int package_partial);
int connection_edge_destroy(circid_t circ_id, edge_connection_t *conn);
int connection_edge_end(edge_connection_t *conn, uint8_t reason);
int connection_edge_end_errno(edge_connection_t *conn);
void connection_edge_end_close(edge_connection_t *conn, uint8_t reason);
int connection_edge_flushed_some(edge_connection_t *conn);
int connection_edge_finished_flushing(edge_connection_t *conn);
int connection_edge_finished_connecting(edge_connection_t *conn);

void connection_entry_set_controller_wait(entry_connection_t *conn);

void connection_ap_about_to_close(entry_connection_t *edge_conn);
void connection_exit_about_to_close(edge_connection_t *edge_conn);

MOCK_DECL(int,
          connection_ap_handshake_send_begin,(entry_connection_t *ap_conn));
int connection_ap_handshake_send_resolve(entry_connection_t *ap_conn);

entry_connection_t  *connection_ap_make_link(connection_t *partner,
                                            char *address, uint16_t port,
                                            const char *digest,
                                            int session_group,
                                            int isolation_flags,
                                            int use_begindir, int want_onehop);
void connection_ap_handshake_socks_reply(entry_connection_t *conn, char *reply,
                                         size_t replylen,
                                         int endreason);
MOCK_DECL(void,connection_ap_handshake_socks_resolved,
          (entry_connection_t *conn,
           int answer_type,
           size_t answer_len,
           const uint8_t *answer,
           int ttl,
           time_t expires));
void connection_ap_handshake_socks_resolved_addr(entry_connection_t *conn,
                                                 const tor_addr_t *answer,
                                                 int ttl,
                                                 time_t expires);

int connection_exit_begin_conn(cell_t *cell, circuit_t *circ);
int connection_exit_begin_resolve(cell_t *cell, or_circuit_t *circ);
void connection_exit_connect(edge_connection_t *conn);
int connection_edge_is_rendezvous_stream(const edge_connection_t *conn);
int connection_ap_can_use_exit(const entry_connection_t *conn,
                               const node_t *exit);
void connection_ap_expire_beginning(void);
void connection_ap_rescan_and_attach_pending(void);
void connection_ap_attach_pending(int retry);
void connection_ap_mark_as_pending_circuit_(entry_connection_t *entry_conn,
                                           const char *file, int line);
#define connection_ap_mark_as_pending_circuit(c) \
  connection_ap_mark_as_pending_circuit_((c), __FILE__, __LINE__)
void connection_ap_mark_as_non_pending_circuit(entry_connection_t *entry_conn);
void connection_ap_mark_as_waiting_for_renddesc(
                                       entry_connection_t *entry_conn);

#define CONNECTION_AP_EXPECT_NONPENDING(c) do {                         \
    if (ENTRY_TO_CONN(c)->state == AP_CONN_STATE_CIRCUIT_WAIT) {        \
      log_warn(LD_BUG, "At %s:%d: %p was unexpectedly in circuit_wait.", \
               __FILE__, __LINE__, (c));                                \
      connection_ap_mark_as_non_pending_circuit(c);                     \
    }                                                                   \
  } while (0)
void connection_ap_fail_onehop(const char *failed_digest,
                               cpath_build_state_t *build_state);
void circuit_discard_optional_exit_enclaves(extend_info_t *info);
int connection_ap_detach_retriable(entry_connection_t *conn,
                                   origin_circuit_t *circ,
                                   int reason);
int connection_ap_process_transparent(entry_connection_t *conn);

int address_is_invalid_destination(const char *address, int client);

MOCK_DECL(int, connection_ap_rewrite_and_attach_if_allowed,
                                                (entry_connection_t *conn,
                                                 origin_circuit_t *circ,
                                                 crypt_path_t *cpath));
int connection_ap_handshake_rewrite_and_attach(entry_connection_t *conn,
                                               origin_circuit_t *circ,
                                               crypt_path_t *cpath);

#if defined(HAVE_NET_IF_H) && defined(HAVE_NET_PFVAR_H)
int get_pf_socket(void);
#endif

int connection_edge_compatible_with_circuit(const entry_connection_t *conn,
                                            const origin_circuit_t *circ);
int connection_edge_update_circuit_isolation(const entry_connection_t *conn,
                                             origin_circuit_t *circ,
                                             int dry_run);
void circuit_clear_isolation(origin_circuit_t *circ);
streamid_t get_unique_stream_id_by_circ(origin_circuit_t *circ);

void connection_edge_free_all(void);

void connection_ap_warn_and_unmark_if_pending_circ(
                                             entry_connection_t *entry_conn,
                                             const char *where);

/** Lowest value for DNS ttl clipping excluding the random addition. */
#define MIN_DNS_TTL (5*60)
/** Highest value for DNS ttl clipping excluding the random addition. */
#define MAX_DNS_TTL (60*60)
/** How long do we keep DNS cache entries before purging them (regardless of
 * their TTL)? */
#define MAX_DNS_ENTRY_AGE (3*60*60)
/** How long do we cache/tell clients to cache DNS records when no TTL is
 * known? */
#define DEFAULT_DNS_TTL (30*60)
/** How much should we +- each TTL to make it fuzzy with uniform sampling at
 * exits?  The value 4 minutes was chosen so that the lowest possible clip is
 * 60s.  Such low clips were used in the past for all TTLs due to a bug in Tor,
 * see "The effect of DNS on Tor's Anonymity" by Greschbach et al.  In other
 * words, sampling such low clips is unlikely to cause any breakage at exits.
 */
#define FUZZY_DNS_TTL (4*60)

uint32_t clip_dns_ttl(uint32_t ttl);
uint32_t clip_dns_fuzzy_ttl(uint32_t ttl);

int connection_half_edge_is_valid_data(const smartlist_t *half_conns,
                                       streamid_t stream_id);
int connection_half_edge_is_valid_sendme(const smartlist_t *half_conns,
                                         streamid_t stream_id);
int connection_half_edge_is_valid_connected(const smartlist_t *half_conns,
                                            streamid_t stream_id);
int connection_half_edge_is_valid_end(smartlist_t *half_conns,
                                      streamid_t stream_id);
int connection_half_edge_is_valid_resolved(smartlist_t *half_conns,
                                           streamid_t stream_id);
bool connection_half_edges_waiting(const origin_circuit_t *circ);

size_t half_streams_get_total_allocation(void);
struct half_edge_t;
void half_edge_free_(struct half_edge_t *he);
#define half_edge_free(he) \
  FREE_AND_NULL(half_edge_t, half_edge_free_, (he))

/** @name Begin-cell flags
 *
 * These flags are used in RELAY_BEGIN cells to change the default behavior
 * of the cell.
 *
 * @{
 **/
/** When this flag is set, the client is willing to get connected to IPv6
 * addresses */
#define BEGIN_FLAG_IPV6_OK        (1u<<0)
/** When this flag is set, the client DOES NOT support connecting to IPv4
 * addresses.  (The sense of this flag is inverted from IPV6_OK, so that the
 * old default behavior of Tor is equivalent to having all flags set to 0.)
 **/
#define BEGIN_FLAG_IPV4_NOT_OK    (1u<<1)
/** When this flag is set, if we find both an IPv4 and an IPv6 address,
 * we use the IPv6 address.  Otherwise we use the IPv4 address. */
#define BEGIN_FLAG_IPV6_PREFERRED (1u<<2)
/**@}*/

#ifdef CONNECTION_EDGE_PRIVATE

STATIC bool parse_extended_hostname(char *address, hostname_type_t *type_out);

/** A parsed BEGIN or BEGIN_DIR cell */
typedef struct begin_cell_t {
  /** The address the client has asked us to connect to, or NULL if this is
   * a BEGIN_DIR cell*/
  char *address;
  /** The flags specified in the BEGIN cell's body.  One or more of
   * BEGIN_FLAG_*. */
  uint32_t flags;
  /** The client's requested port. */
  uint16_t port;
  /** The client's requested Stream ID */
  uint16_t stream_id;
  /** True iff this is a BEGIN_DIR cell. */
  unsigned is_begindir : 1;
} begin_cell_t;

STATIC int begin_cell_parse(const cell_t *cell, begin_cell_t *bcell,
                     uint8_t *end_reason_out);
STATIC int connected_cell_format_payload(uint8_t *payload_out,
                                  const tor_addr_t *addr,
                                  uint32_t ttl);

typedef struct {
  /** Original address, after we lowercased it but before we started
   * mapping it.
   */
  char orig_address[MAX_SOCKS_ADDR_LEN];
  /** True iff the address has been automatically remapped to a local
   * address in VirtualAddrNetwork.  (Only set true when we do a resolve
   * and get a virtual address; not when we connect to the address.) */
  int automap;
  /** If this connection has a .exit address, who put it there? */
  addressmap_entry_source_t exit_source;
  /** If we've rewritten the address, when does this map expire? */
  time_t map_expires;
  /** If we should close the connection, this is the end_reason to pass
   * to connection_mark_unattached_ap */
  int end_reason;
  /** True iff we should close the connection, either because of error or
   * because of successful early RESOLVED reply. */
  int should_close;
} rewrite_result_t;

STATIC void connection_ap_handshake_rewrite(entry_connection_t *conn,
                                            rewrite_result_t *out);

STATIC int connection_ap_process_http_connect(entry_connection_t *conn);
STATIC void export_hs_client_circuit_id(edge_connection_t *edge_conn,
                            hs_circuit_id_protocol_t protocol);

struct half_edge_t;
STATIC void connection_half_edge_add(const edge_connection_t *conn,
                                     origin_circuit_t *circ);
STATIC struct half_edge_t *connection_half_edge_find_stream_id(
                                     const smartlist_t *half_conns,
                                     streamid_t stream_id);
#endif /* defined(CONNECTION_EDGE_PRIVATE) */

#endif /* !defined(TOR_CONNECTION_EDGE_H) */
