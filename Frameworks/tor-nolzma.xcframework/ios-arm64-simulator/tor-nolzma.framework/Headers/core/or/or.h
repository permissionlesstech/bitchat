/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file or.h
 * \brief Master header file for Tor-specific functionality.
 **/

#ifndef TOR_OR_H
#define TOR_OR_H

#include "orconfig.h"
#include "lib/cc/torint.h"

#ifdef HAVE_SIGNAL_H
#include <signal.h>
#endif
#ifdef HAVE_TIME_H
#include <time.h>
#endif

#include "lib/arch/bytes.h"
#include "lib/cc/compat_compiler.h"
#include "lib/container/map.h"
#include "lib/buf/buffers.h"
#include "lib/container/smartlist.h"
#include "lib/crypt_ops/crypto_cipher.h"
#include "lib/crypt_ops/crypto_rsa.h"
#include "lib/ctime/di_ops.h"
#include "lib/defs/dh_sizes.h"
#include "lib/encoding/binascii.h"
#include "lib/encoding/cstring.h"
#include "lib/encoding/time_fmt.h"
#include "lib/err/torerr.h"
#include "lib/fs/dir.h"
#include "lib/fs/files.h"
#include "lib/fs/mmap.h"
#include "lib/fs/path.h"
#include "lib/fs/userdb.h"
#include "lib/geoip/country.h"
#include "lib/intmath/addsub.h"
#include "lib/intmath/bits.h"
#include "lib/intmath/cmp.h"
#include "lib/intmath/logic.h"
#include "lib/intmath/muldiv.h"
#include "lib/log/escape.h"
#include "lib/log/ratelim.h"
#include "lib/log/util_bug.h"
#include "lib/malloc/malloc.h"
#include "lib/net/address.h"
#include "lib/net/inaddr.h"
#include "lib/net/socket.h"
#include "lib/string/compat_ctype.h"
#include "lib/string/compat_string.h"
#include "lib/string/parse_int.h"
#include "lib/string/printf.h"
#include "lib/string/scanf.h"
#include "lib/string/util_string.h"
#include "lib/testsupport/testsupport.h"
#include "lib/thread/threads.h"
#include "lib/time/compat_time.h"
#include "lib/wallclock/approx_time.h"
#include "lib/wallclock/timeval.h"

#include "ht.h"

// These, more than other includes, are for keeping the other struct
// definitions working. We should remove them when we minimize our includes.
#include "core/or/entry_port_cfg_st.h"

struct ed25519_public_key_t;
struct curve25519_public_key_t;

/* These signals are defined to help handle_control_signal work.
 */
#ifndef SIGHUP
#define SIGHUP 1
#endif
#ifndef SIGINT
#define SIGINT 2
#endif
#ifndef SIGUSR1
#define SIGUSR1 10
#endif
#ifndef SIGUSR2
#define SIGUSR2 12
#endif
#ifndef SIGTERM
#define SIGTERM 15
#endif
/* Controller signals start at a high number so we don't
 * conflict with system-defined signals. */
#define SIGNEWNYM 129
#define SIGCLEARDNSCACHE 130
#define SIGHEARTBEAT 131
#define SIGACTIVE 132
#define SIGDORMANT 133

#if (SIZEOF_CELL_T != 0)
/* On Irix, stdlib.h defines a cell_t type, so we need to make sure
 * that our stuff always calls cell_t something different. */
#define cell_t tor_cell_t
#endif

/** Helper macro: Given a pointer to to.base_, of type from*, return &to. */
#define DOWNCAST(to, ptr) ((to*)SUBTYPE_P(ptr, to, base_))

/** Length of longest allowable configured nickname. */
#define MAX_NICKNAME_LEN 19
/** Length of a router identity encoded as a hexadecimal digest, plus
 * possible dollar sign. */
#define MAX_HEX_NICKNAME_LEN (HEX_DIGEST_LEN+1)
/** Maximum length of verbose router identifier: dollar sign, hex ID digest,
 * equal sign or tilde, nickname. */
#define MAX_VERBOSE_NICKNAME_LEN (1+HEX_DIGEST_LEN+1+MAX_NICKNAME_LEN)

/** For HTTP parsing: Maximum number of bytes we'll accept in the headers
 * of an HTTP request or response. */
#define MAX_HEADERS_SIZE 50000

/** Maximum size, in bytes, of a single router descriptor uploaded to us
 * as a directory authority. Caches and clients fetch whatever descriptors
 * the authorities tell them to fetch, and don't care about size. */
#define MAX_DESCRIPTOR_UPLOAD_SIZE 20000

/** Maximum size of a single extrainfo document, as above. */
#define MAX_EXTRAINFO_UPLOAD_SIZE 50000

/** Minimum lifetime for an onion key in days. */
#define MIN_ONION_KEY_LIFETIME_DAYS (1)

/** Maximum lifetime for an onion key in days. */
#define MAX_ONION_KEY_LIFETIME_DAYS (90)

/** Default lifetime for an onion key in days. */
#define DEFAULT_ONION_KEY_LIFETIME_DAYS (28)

/** Minimum grace period for acceptance of an onion key in days.
 * The maximum value is defined in proposal #274 as being the current network
 * consensus parameter for "onion-key-rotation-days". */
#define MIN_ONION_KEY_GRACE_PERIOD_DAYS (1)

/** Default grace period for acceptance of an onion key in days. */
#define DEFAULT_ONION_KEY_GRACE_PERIOD_DAYS (7)

/** How often we should check the network consensus if it is time to rotate or
 * expire onion keys. */
#define ONION_KEY_CONSENSUS_CHECK_INTERVAL (60*60)

/** How often do we rotate TLS contexts? */
#define MAX_SSL_KEY_LIFETIME_INTERNAL (2*60*60)

/** How old do we allow a router to get before removing it
 * from the router list? In seconds. */
#define ROUTER_MAX_AGE (60*60*48)
/** How old can a router get before we (as a server) will no longer
 * consider it live? In seconds. */
#define ROUTER_MAX_AGE_TO_PUBLISH (60*60*24)
/** How old do we let a saved descriptor get before force-removing it? */
#define OLD_ROUTER_DESC_MAX_AGE (60*60*24*5)

/* Proxy client types */
#define PROXY_NONE 0
#define PROXY_CONNECT 1
#define PROXY_SOCKS4 2
#define PROXY_SOCKS5 3
#define PROXY_HAPROXY 4
/* !!!! If there is ever a PROXY_* type over 7, we must grow the proxy_type
 * field in or_connection_t */

/* Pluggable transport proxy type. Don't use this in or_connection_t,
 * instead use the actual underlying proxy type (see above).  */
#define PROXY_PLUGGABLE 5

/** How many circuits do we want simultaneously in-progress to handle
 * a given stream? */
#define MIN_CIRCUITS_HANDLING_STREAM 2

/* These RELAY_COMMAND constants define values for relay cell commands, and
* must match those defined in tor-spec.txt. */
#define RELAY_COMMAND_BEGIN 1
#define RELAY_COMMAND_DATA 2
#define RELAY_COMMAND_END 3
#define RELAY_COMMAND_CONNECTED 4

#define RELAY_COMMAND_SENDME 5
#define RELAY_COMMAND_EXTEND 6
#define RELAY_COMMAND_EXTENDED 7
#define RELAY_COMMAND_TRUNCATE 8
#define RELAY_COMMAND_TRUNCATED 9
#define RELAY_COMMAND_DROP 10

#define RELAY_COMMAND_RESOLVE 11
#define RELAY_COMMAND_RESOLVED 12

#define RELAY_COMMAND_BEGIN_DIR 13
#define RELAY_COMMAND_EXTEND2 14
#define RELAY_COMMAND_EXTENDED2 15

/* Conflux */
#define RELAY_COMMAND_CONFLUX_LINK 19
#define RELAY_COMMAND_CONFLUX_LINKED 20
#define RELAY_COMMAND_CONFLUX_LINKED_ACK 21
#define RELAY_COMMAND_CONFLUX_SWITCH 22

#define RELAY_COMMAND_ESTABLISH_INTRO 32
#define RELAY_COMMAND_ESTABLISH_RENDEZVOUS 33
#define RELAY_COMMAND_INTRODUCE1 34
#define RELAY_COMMAND_INTRODUCE2 35
#define RELAY_COMMAND_RENDEZVOUS1 36
#define RELAY_COMMAND_RENDEZVOUS2 37
#define RELAY_COMMAND_INTRO_ESTABLISHED 38
#define RELAY_COMMAND_RENDEZVOUS_ESTABLISHED 39
#define RELAY_COMMAND_INTRODUCE_ACK 40

#define RELAY_COMMAND_PADDING_NEGOTIATE 41
#define RELAY_COMMAND_PADDING_NEGOTIATED 42

#define RELAY_COMMAND_XOFF 43
#define RELAY_COMMAND_XON 44

/* Reasons why an OR connection is closed. */
#define END_OR_CONN_REASON_DONE           1
#define END_OR_CONN_REASON_REFUSED        2 /* connection refused */
#define END_OR_CONN_REASON_OR_IDENTITY    3
#define END_OR_CONN_REASON_CONNRESET      4 /* connection reset by peer */
#define END_OR_CONN_REASON_TIMEOUT        5
#define END_OR_CONN_REASON_NO_ROUTE       6 /* no route to host/net */
#define END_OR_CONN_REASON_IO_ERROR       7 /* read/write error */
#define END_OR_CONN_REASON_RESOURCE_LIMIT 8 /* sockets, buffers, etc */
#define END_OR_CONN_REASON_PT_MISSING     9 /* PT failed or not available */
#define END_OR_CONN_REASON_TLS_ERROR      10 /* Problem in TLS protocol */
#define END_OR_CONN_REASON_MISC           11

/* Reasons why we (or a remote OR) might close a stream. See tor-spec.txt for
 * documentation of these.  The values must match. */
#define END_STREAM_REASON_MISC 1
#define END_STREAM_REASON_RESOLVEFAILED 2
#define END_STREAM_REASON_CONNECTREFUSED 3
#define END_STREAM_REASON_EXITPOLICY 4
#define END_STREAM_REASON_DESTROY 5
#define END_STREAM_REASON_DONE 6
#define END_STREAM_REASON_TIMEOUT 7
#define END_STREAM_REASON_NOROUTE 8
#define END_STREAM_REASON_HIBERNATING 9
#define END_STREAM_REASON_INTERNAL 10
#define END_STREAM_REASON_RESOURCELIMIT 11
#define END_STREAM_REASON_CONNRESET 12
#define END_STREAM_REASON_TORPROTOCOL 13
#define END_STREAM_REASON_NOTDIRECTORY 14
#define END_STREAM_REASON_ENTRYPOLICY 15

/* These high-numbered end reasons are not part of the official spec,
 * and are not intended to be put in relay end cells. They are here
 * to be more informative when sending back socks replies to the
 * application. */
/* XXXX 256 is no longer used; feel free to reuse it. */
/** We were unable to attach the connection to any circuit at all. */
/* XXXX the ways we use this one don't make a lot of sense. */
#define END_STREAM_REASON_CANT_ATTACH 257
/** We can't connect to any directories at all, so we killed our streams
 * before they can time out. */
#define END_STREAM_REASON_NET_UNREACHABLE 258
/** This is a SOCKS connection, and the client used (or misused) the SOCKS
 * protocol in a way we couldn't handle. */
#define END_STREAM_REASON_SOCKSPROTOCOL 259
/** This is a transparent proxy connection, but we can't extract the original
 * target address:port. */
#define END_STREAM_REASON_CANT_FETCH_ORIG_DEST 260
/** This is a connection on the NATD port, and the destination IP:Port was
 * either ill-formed or out-of-range. */
#define END_STREAM_REASON_INVALID_NATD_DEST 261
/** The target address is in a private network (like 127.0.0.1 or 10.0.0.1);
 * you don't want to do that over a randomly chosen exit */
#define END_STREAM_REASON_PRIVATE_ADDR 262
/** This is an HTTP tunnel connection and the client used or misused HTTP in a
 * way we can't handle.
 */
#define END_STREAM_REASON_HTTPPROTOCOL 263

/** Bitwise-and this value with endreason to mask out all flags. */
#define END_STREAM_REASON_MASK 511

/** Bitwise-or this with the argument to control_event_stream_status
 * to indicate that the reason came from an END cell. */
#define END_STREAM_REASON_FLAG_REMOTE 512
/** Bitwise-or this with the argument to control_event_stream_status
 * to indicate that we already sent a CLOSED stream event. */
#define END_STREAM_REASON_FLAG_ALREADY_SENT_CLOSED 1024
/** Bitwise-or this with endreason to indicate that we already sent
 * a socks reply, and no further reply needs to be sent from
 * connection_mark_unattached_ap(). */
#define END_STREAM_REASON_FLAG_ALREADY_SOCKS_REPLIED 2048

/* 'type' values to use in RESOLVED cells.  Specified in tor-spec.txt. */
#define RESOLVED_TYPE_HOSTNAME 0
#define RESOLVED_TYPE_IPV4 4
#define RESOLVED_TYPE_IPV6 6
#define RESOLVED_TYPE_ERROR_TRANSIENT 0xF0
#define RESOLVED_TYPE_ERROR 0xF1

/* Negative reasons are internal: we never send them in a DESTROY or TRUNCATE
 * call; they only go to the controller for tracking  */

/* Closing introduction point that were opened in parallel. */
#define END_CIRC_REASON_IP_NOW_REDUNDANT -4

/** Our post-timeout circuit time measurement period expired.
 * We must give up now */
#define END_CIRC_REASON_MEASUREMENT_EXPIRED -3

/** We couldn't build a path for this circuit. */
#define END_CIRC_REASON_NOPATH          -2
/** Catch-all "other" reason for closing origin circuits. */
#define END_CIRC_AT_ORIGIN              -1

/* Reasons why we (or a remote OR) might close a circuit. See tor-spec.txt
 * section 5.4 for documentation of these. */
#define END_CIRC_REASON_MIN_            0
#define END_CIRC_REASON_NONE            0
#define END_CIRC_REASON_TORPROTOCOL     1
#define END_CIRC_REASON_INTERNAL        2
#define END_CIRC_REASON_REQUESTED       3
#define END_CIRC_REASON_HIBERNATING     4
#define END_CIRC_REASON_RESOURCELIMIT   5
#define END_CIRC_REASON_CONNECTFAILED   6
#define END_CIRC_REASON_OR_IDENTITY     7
#define END_CIRC_REASON_CHANNEL_CLOSED  8
#define END_CIRC_REASON_FINISHED        9
#define END_CIRC_REASON_TIMEOUT         10
#define END_CIRC_REASON_DESTROYED       11
#define END_CIRC_REASON_NOSUCHSERVICE   12
#define END_CIRC_REASON_MAX_            12

/** Bitwise-OR this with the argument to circuit_mark_for_close() or
 * control_event_circuit_status() to indicate that the reason was
 * passed through from a destroy or truncate cell. */
#define END_CIRC_REASON_FLAG_REMOTE     512

/** Length of v2 descriptor ID (32 base32 chars = 160 bits).
 *
 * XXX: It is still used by v3 code but should be renamed or maybe removed. */
#define REND_DESC_ID_V2_LEN_BASE32 BASE32_DIGEST_LEN

/** Maximum length of authorized client names for a hidden service. */
#define REND_CLIENTNAME_MAX_LEN 16

/** Length of the rendezvous cookie that is used to connect circuits at the
 * rendezvous point. */
#define REND_COOKIE_LEN DIGEST_LEN

/** Client authorization type that a hidden service performs. */
typedef enum rend_auth_type_t {
  REND_NO_AUTH      = 0,
  REND_V3_AUTH      = 1, /* Dummy flag to allow adding v3 services on the
                          * control port */
} rend_auth_type_t;

/* Stub because we can't include hs_ident.h. */
struct hs_ident_edge_conn_t;
struct hs_ident_dir_conn_t;
struct hs_ident_circuit_t;

typedef struct hsdir_index_t hsdir_index_t;

/** Time interval for tracking replays of DH public keys received in
 * INTRODUCE2 cells.  Used only to avoid launching multiple
 * simultaneous attempts to connect to the same rendezvous point. */
#define REND_REPLAY_TIME_INTERVAL (5 * 60)

/** Used to indicate which way a cell is going on a circuit. */
typedef enum {
  CELL_DIRECTION_IN=1, /**< The cell is moving towards the origin. */
  CELL_DIRECTION_OUT=2, /**< The cell is moving away from the origin. */
} cell_direction_t;

/**
 * An enum to allow us to specify which channel in a circuit
 * we're interested in.
 *
 * This is needed because our data structures and other fields
 * for channel delivery are disassociated from the channel.
 */
typedef enum {
  CIRCUIT_N_CHAN = 0,
  CIRCUIT_P_CHAN = 1
} circuit_channel_direction_t;

/** Initial value for both sides of a circuit transmission window when the
 * circuit is initialized.  Measured in cells. */
#define CIRCWINDOW_START 1000
#define CIRCWINDOW_START_MIN 100
#define CIRCWINDOW_START_MAX 1000
/** Amount to increment a circuit window when we get a circuit SENDME. */
#define CIRCWINDOW_INCREMENT 100
/** Initial value on both sides of a stream transmission window when the
 * stream is initialized.  Measured in cells. */
#define STREAMWINDOW_START 500
#define STREAMWINDOW_START_MAX 500
/** Amount to increment a stream window when we get a stream SENDME. */
#define STREAMWINDOW_INCREMENT 50

/** Maximum number of queued cells on a circuit for which we are the
 * midpoint before we give up and kill it.  This must be >= circwindow
 * to avoid killing innocent circuits, and >= circwindow*2 to give
 * leaky-pipe a chance of working someday. The ORCIRC_MAX_MIDDLE_KILL_THRESH
 * ratio controls the margin of error between emitting a warning and
 * killing the circuit.
 */
#define ORCIRC_MAX_MIDDLE_CELLS (CIRCWINDOW_START_MAX*2)
/** Ratio of hard (circuit kill) to soft (warning) thresholds for the
 * ORCIRC_MAX_MIDDLE_CELLS tests.
 */
#define ORCIRC_MAX_MIDDLE_KILL_THRESH (1.1f)

/* Cell commands.  These values are defined in tor-spec.txt. */
#define CELL_PADDING 0
#define CELL_CREATE 1
#define CELL_CREATED 2
#define CELL_RELAY 3
#define CELL_DESTROY 4
#define CELL_CREATE_FAST 5
#define CELL_CREATED_FAST 6
#define CELL_VERSIONS 7
#define CELL_NETINFO 8
#define CELL_RELAY_EARLY 9
#define CELL_CREATE2 10
#define CELL_CREATED2 11
#define CELL_PADDING_NEGOTIATE 12

#define CELL_VPADDING 128
#define CELL_CERTS 129
#define CELL_AUTH_CHALLENGE 130
#define CELL_AUTHENTICATE 131
#define CELL_AUTHORIZE 132
#define CELL_COMMAND_MAX_ 132

/** How long to test reachability before complaining to the user. */
#define TIMEOUT_UNTIL_UNREACHABILITY_COMPLAINT (20*60)

/** Legal characters in a nickname. */
#define LEGAL_NICKNAME_CHARACTERS \
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

/** Name chosen by routers that don't configure nicknames */
#define UNNAMED_ROUTER_NICKNAME "Unnamed"

/** Number of bytes in a SOCKS4 header. */
#define SOCKS4_NETWORK_LEN 8

/*
 * Relay payload:
 *         Relay command           [1 byte]
 *         Recognized              [2 bytes]
 *         Stream ID               [2 bytes]
 *         Partial SHA-1           [4 bytes]
 *         Length                  [2 bytes]
 *         Relay payload           [498 bytes]
 */

/** Number of bytes in a cell, minus cell header. */
#define CELL_PAYLOAD_SIZE 509
/** Number of bytes in a cell transmitted over the network, in the longest
 * form */
#define CELL_MAX_NETWORK_SIZE 514

/** Maximum length of a header on a variable-length cell. */
#define VAR_CELL_MAX_HEADER_SIZE 7

static int get_cell_network_size(int wide_circ_ids);
static inline int get_cell_network_size(int wide_circ_ids)
{
  return wide_circ_ids ? CELL_MAX_NETWORK_SIZE : CELL_MAX_NETWORK_SIZE - 2;
}
static int get_var_cell_header_size(int wide_circ_ids);
static inline int get_var_cell_header_size(int wide_circ_ids)
{
  return wide_circ_ids ? VAR_CELL_MAX_HEADER_SIZE :
    VAR_CELL_MAX_HEADER_SIZE - 2;
}
static int get_circ_id_size(int wide_circ_ids);
static inline int get_circ_id_size(int wide_circ_ids)
{
  return wide_circ_ids ? 4 : 2;
}

/** Number of bytes in a relay cell's header (not including general cell
 * header). */
#define RELAY_HEADER_SIZE (1+2+2+4+2)
/** Largest number of bytes that can fit in a relay cell payload. */
#define RELAY_PAYLOAD_SIZE (CELL_PAYLOAD_SIZE-RELAY_HEADER_SIZE)

/** Identifies a circuit on an or_connection */
typedef uint32_t circid_t;
/** Identifies a stream on a circuit */
typedef uint16_t streamid_t;

/* channel_t typedef; struct channel_t is in channel.h */

typedef struct channel_t channel_t;

/* channel_listener_t typedef; struct channel_listener_t is in channel.h */

typedef struct channel_listener_t channel_listener_t;

/* TLS channel stuff */

typedef struct channel_tls_t channel_tls_t;

/* circuitmux_t typedef; struct circuitmux_t is in circuitmux.h */

typedef struct circuitmux_t circuitmux_t;

typedef struct cell_t cell_t;
typedef struct var_cell_t var_cell_t;
typedef struct packed_cell_t packed_cell_t;
typedef struct cell_queue_t cell_queue_t;
typedef struct destroy_cell_t destroy_cell_t;
typedef struct destroy_cell_queue_t destroy_cell_queue_t;
typedef struct ext_or_cmd_t ext_or_cmd_t;

/** Beginning of a RELAY cell payload. */
typedef struct {
  uint8_t command; /**< The end-to-end relay command. */
  uint16_t recognized; /**< Used to tell whether cell is for us. */
  streamid_t stream_id; /**< Which stream is this cell associated with? */
  char integrity[4]; /**< Used to tell whether cell is corrupted. */
  uint16_t length; /**< How long is the payload body? */
} relay_header_t;

typedef struct socks_request_t socks_request_t;
typedef struct entry_port_cfg_t entry_port_cfg_t;
typedef struct server_port_cfg_t server_port_cfg_t;

/** Minimum length of the random part of an AUTH_CHALLENGE cell. */
#define OR_AUTH_CHALLENGE_LEN 32

/**
 * @name Certificate types for CERTS cells.
 *
 * These values are defined by the protocol, and affect how an X509
 * certificate in a CERTS cell is interpreted and used.
 *
 * @{ */
/** A certificate that authenticates a TLS link key.  The subject key
 * must match the key used in the TLS handshake; it must be signed by
 * the identity key. */
#define OR_CERT_TYPE_TLS_LINK 1
/** A self-signed identity certificate. The subject key must be a
 * 1024-bit RSA key. */
#define OR_CERT_TYPE_ID_1024 2
/** A certificate that authenticates a key used in an AUTHENTICATE cell
 * in the v3 handshake.  The subject key must be a 1024-bit RSA key; it
 * must be signed by the identity key */
#define OR_CERT_TYPE_AUTH_1024 3
/* DOCDOC */
#define OR_CERT_TYPE_RSA_ED_CROSSCERT 7
/**@}*/

/** The first supported type of AUTHENTICATE cell.  It contains
 * a bunch of structures signed with an RSA1024 key.  The signed
 * structures include a HMAC using negotiated TLS secrets, and a digest
 * of all cells sent or received before the AUTHENTICATE cell (including
 * the random server-generated AUTH_CHALLENGE cell).
 */
#define AUTHTYPE_RSA_SHA256_TLSSECRET 1
/** As AUTHTYPE_RSA_SHA256_TLSSECRET, but instead of using the
 * negotiated TLS secrets, uses exported keying material from the TLS
 * session as described in RFC 5705.
 *
 * Not used by today's tors, since everything that supports this
 * also supports ED25519_SHA256_5705, which is better.
 **/
#define AUTHTYPE_RSA_SHA256_RFC5705 2
/** As AUTHTYPE_RSA_SHA256_RFC5705, but uses an Ed25519 identity key to
 * authenticate.  */
#define AUTHTYPE_ED25519_SHA256_RFC5705 3
/*
 * NOTE: authchallenge_type_is_better() relies on these AUTHTYPE codes
 * being sorted in order of preference.  If we someday add one with
 * a higher numerical value that we don't like as much, we should revise
 * authchallenge_type_is_better().
 */

/** The length of the part of the AUTHENTICATE cell body that the client and
 * server can generate independently (when using RSA_SHA256_TLSSECRET). It
 * contains everything except the client's timestamp, the client's randomly
 * generated nonce, and the signature. */
#define V3_AUTH_FIXED_PART_LEN (8+(32*6))
/** The length of the part of the AUTHENTICATE cell body that the client
 * signs. */
#define V3_AUTH_BODY_LEN (V3_AUTH_FIXED_PART_LEN + 8 + 16)

typedef struct or_handshake_certs_t or_handshake_certs_t;
typedef struct or_handshake_state_t or_handshake_state_t;

/** Length of Extended ORPort connection identifier. */
#define EXT_OR_CONN_ID_LEN DIGEST_LEN /* 20 */

typedef struct connection_t connection_t;
typedef struct control_connection_t control_connection_t;
typedef struct dir_connection_t dir_connection_t;
typedef struct edge_connection_t edge_connection_t;
typedef struct entry_connection_t entry_connection_t;
typedef struct listener_connection_t listener_connection_t;
typedef struct or_connection_t or_connection_t;

/** Cast a connection_t subtype pointer to a connection_t **/
#define TO_CONN(c) (&(((c)->base_)))

/** Cast a entry_connection_t subtype pointer to a connection_t **/
#define ENTRY_TO_CONN(c) (TO_CONN(ENTRY_TO_EDGE_CONN(c)))

typedef struct addr_policy_t addr_policy_t;

typedef struct cached_dir_t cached_dir_t;

/** Enum used to remember where a signed_descriptor_t is stored and how to
 * manage the memory for signed_descriptor_body.  */
typedef enum {
  /** The descriptor isn't stored on disk at all: the copy in memory is
   * canonical; the saved_offset field is meaningless. */
  SAVED_NOWHERE=0,
  /** The descriptor is stored in the cached_routers file: the
   * signed_descriptor_body is meaningless; the signed_descriptor_len and
   * saved_offset are used to index into the mmaped cache file. */
  SAVED_IN_CACHE,
  /** The descriptor is stored in the cached_routers.new file: the
   * signed_descriptor_body and saved_offset fields are both set. */
  /* FFFF (We could also mmap the file and grow the mmap as needed, or
   * lazy-load the descriptor text by using seek and read.  We don't, for
   * now.)
   */
  SAVED_IN_JOURNAL
} saved_location_t;
#define saved_location_bitfield_t ENUM_BF(saved_location_t)

/** Enumeration: what directory object is being downloaded?
 * This determines which schedule is selected to perform the download. */
typedef enum {
  DL_SCHED_GENERIC = 0,
  DL_SCHED_CONSENSUS = 1,
  DL_SCHED_BRIDGE = 2,
} download_schedule_t;
#define download_schedule_bitfield_t ENUM_BF(download_schedule_t)

/** Enumeration: is the download schedule for downloading from an authority,
 * or from any available directory mirror?
 * During bootstrap, "any" means a fallback (or an authority, if there
 * are no fallbacks).
 * When we have a valid consensus, "any" means any directory server. */
typedef enum {
  DL_WANT_ANY_DIRSERVER = 0,
  DL_WANT_AUTHORITY = 1,
} download_want_authority_t;
#define download_want_authority_bitfield_t \
                                        ENUM_BF(download_want_authority_t)

/** Enumeration: do we want to increment the schedule position each time a
 * connection is attempted (these attempts can be concurrent), or do we want
 * to increment the schedule position after a connection fails? */
typedef enum {
  DL_SCHED_INCREMENT_FAILURE = 0,
  DL_SCHED_INCREMENT_ATTEMPT = 1,
} download_schedule_increment_t;
#define download_schedule_increment_bitfield_t \
                                        ENUM_BF(download_schedule_increment_t)

typedef struct download_status_t download_status_t;

/** If n_download_failures is this high, the download can never happen. */
#define IMPOSSIBLE_TO_DOWNLOAD 255

/** The max size we expect router descriptor annotations we create to
 * be. We'll accept larger ones if we see them on disk, but we won't
 * create any that are larger than this. */
#define ROUTER_ANNOTATION_BUF_LEN 256

typedef struct signed_descriptor_t signed_descriptor_t;

/** Flags used to summarize the declared protocol versions of a relay,
 * so we don't need to parse them again and again. */
typedef struct protover_summary_flags_t {
  /** True iff we have a proto line for this router, or a versions line
   * from which we could infer the protocols. */
  unsigned int protocols_known:1;

  /** True iff this router has a version or protocol list that allows it to
   * accept EXTEND2 cells. This requires Relay=2. */
  unsigned int supports_extend2_cells:1;

  /** True iff this router has a version or protocol list that allows it to
   * accept IPv6 connections. This requires Relay=2 or Relay=3. */
  unsigned int supports_accepting_ipv6_extends:1;

  /** True iff this router has a version or protocol list that allows it to
   * initiate IPv6 connections. This requires Relay=3. */
  unsigned int supports_initiating_ipv6_extends:1;

  /** True iff this router has a version or protocol list that allows it to
   * consider IPv6 connections canonical. This requires Relay=3. */
  unsigned int supports_canonical_ipv6_conns:1;

  /** True iff this router has a protocol list that allows it to negotiate
   * ed25519 identity keys on a link handshake with us. This
   * requires LinkAuth=3. */
  unsigned int supports_ed25519_link_handshake_compat:1;

  /** True iff this router has a protocol list that allows it to negotiate
   * ed25519 identity keys on a link handshake, at all. This requires some
   * LinkAuth=X for X >= 3. */
  unsigned int supports_ed25519_link_handshake_any:1;

  /** True iff this router has a protocol list that allows it to be an
   * introduction point supporting ed25519 authentication key which is part of
   * the v3 protocol detailed in proposal 224. This requires HSIntro=4. */
  unsigned int supports_ed25519_hs_intro : 1;

  /** True iff this router has a protocol list that allows it to support the
   * ESTABLISH_INTRO DoS cell extension. Requires HSIntro=5. */
  unsigned int supports_establish_intro_dos_extension : 1;

  /** True iff this router has a protocol list that allows it to be an hidden
   * service directory supporting version 3 as seen in proposal 224. This
   * requires HSDir=2. */
  unsigned int supports_v3_hsdir : 1;

  /** True iff this router has a protocol list that allows it to be an hidden
   * service rendezvous point supporting version 3 as seen in proposal 224.
   * This requires HSRend=2. */
  unsigned int supports_v3_rendezvous_point: 1;

  /** True iff this router has a protocol list that allows clients to
   * negotiate hs circuit setup padding. Requires Padding=2. */
  unsigned int supports_hs_setup_padding : 1;

  /** True iff this router supports congestion control.
   * Requires both FlowCtrl=2 *and* Relay=4 */
  unsigned int supports_congestion_control : 1;

  /** True iff this router supports conflux. Requires Relay=5 */
  unsigned int supports_conflux : 1;
} protover_summary_flags_t;

typedef struct routerinfo_t routerinfo_t;
typedef struct extrainfo_t extrainfo_t;
typedef struct routerstatus_t routerstatus_t;

typedef struct microdesc_t microdesc_t;
typedef struct node_t node_t;
typedef struct vote_microdesc_hash_t vote_microdesc_hash_t;
typedef struct vote_routerstatus_t vote_routerstatus_t;
typedef struct document_signature_t document_signature_t;
typedef struct networkstatus_voter_info_t networkstatus_voter_info_t;
typedef struct networkstatus_sr_info_t networkstatus_sr_info_t;

/** Enumerates recognized flavors of a consensus networkstatus document.  All
 * flavors of a consensus are generated from the same set of votes, but they
 * present different types information to different versions of Tor. */
typedef enum {
  FLAV_NS = 0,
  FLAV_MICRODESC = 1,
} consensus_flavor_t;

/** How many different consensus flavors are there? */
#define N_CONSENSUS_FLAVORS ((int)(FLAV_MICRODESC)+1)

typedef struct networkstatus_t networkstatus_t;
typedef struct ns_detached_signatures_t ns_detached_signatures_t;
typedef struct desc_store_t desc_store_t;
typedef struct routerlist_t routerlist_t;
typedef struct extend_info_t extend_info_t;
typedef struct authority_cert_t authority_cert_t;

/** Bitfield enum type listing types of information that directory authorities
 * can be authoritative about, and that directory caches may or may not cache.
 *
 * Note that the granularity here is based on authority granularity and on
 * cache capabilities.  Thus, one particular bit may correspond in practice to
 * a few types of directory info, so long as every authority that pronounces
 * officially about one of the types prounounces officially about all of them,
 * and so long as every cache that caches one of them caches all of them.
 */
typedef enum {
  NO_DIRINFO      = 0,
  /** Serves/signs v3 directory information: votes, consensuses, certs */
  V3_DIRINFO      = 1 << 2,
  /** Serves bridge descriptors. */
  BRIDGE_DIRINFO  = 1 << 4,
  /** Serves extrainfo documents. */
  EXTRAINFO_DIRINFO=1 << 5,
  /** Serves microdescriptors. */
  MICRODESC_DIRINFO=1 << 6,
} dirinfo_type_t;

#define ALL_DIRINFO ((dirinfo_type_t)((1<<7)-1))

#define ONION_HANDSHAKE_TYPE_TAP  0x0000
#define ONION_HANDSHAKE_TYPE_FAST 0x0001
#define ONION_HANDSHAKE_TYPE_NTOR 0x0002
#define ONION_HANDSHAKE_TYPE_NTOR_V3 0x0003
#define MAX_ONION_HANDSHAKE_TYPE 0x0003

typedef struct onion_handshake_state_t onion_handshake_state_t;
typedef struct relay_crypto_t relay_crypto_t;
typedef struct crypt_path_t crypt_path_t;
typedef struct crypt_path_reference_t crypt_path_reference_t;

#define CPATH_KEY_MATERIAL_LEN (20*2+16*2)

typedef struct cpath_build_state_t cpath_build_state_t;

struct create_cell_t;

/** Entry in the cell stats list of a circuit; used only if CELL_STATS
 * events are enabled. */
typedef struct testing_cell_stats_entry_t {
  uint8_t command; /**< cell command number. */
  /** Waiting time in centiseconds if this event is for a removed cell,
   * or 0 if this event is for adding a cell to the queue.  22 bits can
   * store more than 11 hours, enough to assume that a circuit with this
   * delay would long have been closed. */
  unsigned int waiting_time:22;
  unsigned int removed:1; /**< 0 for added to, 1 for removed from queue. */
  unsigned int exitward:1; /**< 0 for app-ward, 1 for exit-ward. */
} testing_cell_stats_entry_t;

typedef struct circuit_t circuit_t;
typedef struct origin_circuit_t origin_circuit_t;
typedef struct or_circuit_t or_circuit_t;

/** Largest number of relay_early cells that we can send on a given
 * circuit. */
#define MAX_RELAY_EARLY_CELLS_PER_CIRCUIT 8

typedef enum path_state_t path_state_t;
#define path_state_bitfield_t ENUM_BF(path_state_t)

#if REND_COOKIE_LEN != DIGEST_LEN
#error "The REND_TOKEN_LEN macro assumes REND_COOKIE_LEN == DIGEST_LEN"
#endif
#define REND_TOKEN_LEN DIGEST_LEN

/** Convert a circuit subtype to a circuit_t. */
#define TO_CIRCUIT(x)  (&((x)->base_))

/** @name Isolation flags

    Ways to isolate client streams

    @{
*/
/** Isolate based on destination port */
#define ISO_DESTPORT    (1u<<0)
/** Isolate based on destination address */
#define ISO_DESTADDR    (1u<<1)
/** Isolate based on SOCKS authentication */
#define ISO_SOCKSAUTH   (1u<<2)
/** Isolate based on client protocol choice */
#define ISO_CLIENTPROTO (1u<<3)
/** Isolate based on client address */
#define ISO_CLIENTADDR  (1u<<4)
/** Isolate based on session group (always on). */
#define ISO_SESSIONGRP  (1u<<5)
/** Isolate based on newnym epoch (always on). */
#define ISO_NYM_EPOCH   (1u<<6)
/** Isolate all streams (Internal only). */
#define ISO_STREAM      (1u<<7)
/**@}*/

/** Default isolation level for ports. */
#define ISO_DEFAULT (ISO_CLIENTADDR|ISO_SOCKSAUTH|ISO_SESSIONGRP|ISO_NYM_EPOCH)

/** Indicates that we haven't yet set a session group on a port_cfg_t. */
#define SESSION_GROUP_UNSET -1
/** Session group reserved for directory connections */
#define SESSION_GROUP_DIRCONN -2
/** Session group reserved for resolve requests launched by a controller */
#define SESSION_GROUP_CONTROL_RESOLVE -3
/** First automatically allocated session group number */
#define SESSION_GROUP_FIRST_AUTO -4

typedef struct port_cfg_t port_cfg_t;
typedef struct routerset_t routerset_t;

/** A magic value for the (Socks|OR|...)Port options below, telling Tor
 * to pick its own port. */
#define CFG_AUTO_PORT 0xc4005e

typedef struct or_options_t or_options_t;

typedef struct or_state_t or_state_t;

#define MAX_SOCKS_ADDR_LEN 256

/********************************* circuitbuild.c **********************/

/** How many hops does a general-purpose circuit have by default? */
#define DEFAULT_ROUTE_LEN 3

/* Circuit Build Timeout "public" structures. */

/** Precision multiplier for the Bw weights */
#define BW_WEIGHT_SCALE   10000
#define BW_MIN_WEIGHT_SCALE 1
#define BW_MAX_WEIGHT_SCALE INT32_MAX

typedef struct circuit_build_times_t circuit_build_times_t;

/********************************* config.c ***************************/

/********************************* connection_edge.c *************************/

/** Enumerates possible origins of a client-side address mapping. */
typedef enum {
  /** We're remapping this address because the controller told us to. */
  ADDRMAPSRC_CONTROLLER,
  /** We're remapping this address because of an AutomapHostsOnResolve
   * configuration. */
  ADDRMAPSRC_AUTOMAP,
  /** We're remapping this address because our configuration (via torrc, the
   * command line, or a SETCONF command) told us to. */
  ADDRMAPSRC_TORRC,
  /** We're remapping this address because we have TrackHostExit configured,
   * and we want to remember to use the same exit next time. */
  ADDRMAPSRC_TRACKEXIT,
  /** We're remapping this address because we got a DNS resolution from a
   * Tor server that told us what its value was. */
  ADDRMAPSRC_DNS,

  /** No remapping has occurred.  This isn't a possible value for an
   * addrmap_entry_t; it's used as a null value when we need to answer "Why
   * did this remapping happen." */
  ADDRMAPSRC_NONE
} addressmap_entry_source_t;
#define addressmap_entry_source_bitfield_t ENUM_BF(addressmap_entry_source_t)

#define WRITE_STATS_INTERVAL (24*60*60)

/********************************* dirvote.c ************************/

typedef struct vote_timing_t vote_timing_t;

/********************************* microdesc.c *************************/

typedef struct microdesc_cache_t microdesc_cache_t;

/** The maximum number of non-circuit-build-timeout failures a hidden
 * service client will tolerate while trying to build a circuit to an
 * introduction point. */
#define MAX_INTRO_POINT_REACHABILITY_FAILURES 5

/** The minimum and maximum number of distinct INTRODUCE2 cells which a
 * hidden service's introduction point will receive before it begins to
 * expire. */
#define INTRO_POINT_MIN_LIFETIME_INTRODUCTIONS 16384
/* Double the minimum value so the interval is [min, min * 2]. */
#define INTRO_POINT_MAX_LIFETIME_INTRODUCTIONS \
  (INTRO_POINT_MIN_LIFETIME_INTRODUCTIONS * 2)

/** The minimum number of seconds that an introduction point will last
 * before expiring due to old age.  (If it receives
 * INTRO_POINT_LIFETIME_INTRODUCTIONS INTRODUCE2 cells, it may expire
 * sooner.)
 *
 * XXX Should this be configurable? */
#define INTRO_POINT_LIFETIME_MIN_SECONDS (18*60*60)
/** The maximum number of seconds that an introduction point will last
 * before expiring due to old age.
 *
 * XXX Should this be configurable? */
#define INTRO_POINT_LIFETIME_MAX_SECONDS (24*60*60)

/** The maximum number of circuit creation retry we do to an intro point
 * before giving up. We try to reuse intro point that fails during their
 * lifetime so this is a hard limit on the amount of time we do that. */
#define MAX_INTRO_POINT_CIRCUIT_RETRIES 3

/********************************* routerlist.c ***************************/

typedef struct dir_server_t dir_server_t;

#define RELAY_REQUIRED_MIN_BANDWIDTH (75*1024)
#define BRIDGE_REQUIRED_MIN_BANDWIDTH (50*1024)

#define ROUTER_MAX_DECLARED_BANDWIDTH INT32_MAX

typedef struct tor_version_t tor_version_t;

#endif /* !defined(TOR_OR_H) */
