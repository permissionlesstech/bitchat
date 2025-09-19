/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file connection.h
 * \brief Header file for connection.c.
 **/

#ifndef TOR_CONNECTION_H
#define TOR_CONNECTION_H

#include "lib/smartlist_core/smartlist_core.h"
#include "lib/log/log.h"

#ifdef HAVE_SYS_SOCKET_H
#include <sys/socket.h>
#endif

struct listener_connection_t;
struct connection_t;
struct dir_connection_t;
struct or_connection_t;
struct edge_connection_t;
struct entry_connection_t;
struct control_connection_t;
struct port_cfg_t;
struct tor_addr_t;
struct or_options_t;

struct listener_connection_t *TO_LISTENER_CONN(struct connection_t *);
const struct listener_connection_t *CONST_TO_LISTENER_CONN(
                                      const struct connection_t *);

struct buf_t;

#define CONN_TYPE_MIN_ 3
/** Type for sockets listening for OR connections. */
#define CONN_TYPE_OR_LISTENER 3
/** A bidirectional TLS connection transmitting a sequence of cells.
 * May be from an OR to an OR, or from an OP to an OR. */
#define CONN_TYPE_OR 4
/** A TCP connection from an onion router to a stream's destination. */
#define CONN_TYPE_EXIT 5
/** Type for sockets listening for SOCKS connections. */
#define CONN_TYPE_AP_LISTENER 6
/** A SOCKS proxy connection from the user application to the onion
 * proxy. */
#define CONN_TYPE_AP 7
/** Type for sockets listening for HTTP connections to the directory server. */
#define CONN_TYPE_DIR_LISTENER 8
/** Type for HTTP connections to the directory server. */
#define CONN_TYPE_DIR 9
/* Type 10 is unused. */
/** Type for listening for connections from user interface process. */
#define CONN_TYPE_CONTROL_LISTENER 11
/** Type for connections from user interface process. */
#define CONN_TYPE_CONTROL 12
/** Type for sockets listening for transparent connections redirected by pf or
 * netfilter. */
#define CONN_TYPE_AP_TRANS_LISTENER 13
/** Type for sockets listening for transparent connections redirected by
 * natd. */
#define CONN_TYPE_AP_NATD_LISTENER 14
/** Type for sockets listening for DNS requests. */
#define CONN_TYPE_AP_DNS_LISTENER 15

/** Type for connections from the Extended ORPort. */
#define CONN_TYPE_EXT_OR 16
/** Type for sockets listening for Extended ORPort connections. */
#define CONN_TYPE_EXT_OR_LISTENER 17
/** Type for sockets listening for HTTP CONNECT tunnel connections. */
#define CONN_TYPE_AP_HTTP_CONNECT_LISTENER 18
/** Type for sockets listening for Metrics query connections. */
#define CONN_TYPE_METRICS_LISTENER 19
/** Type for connections from metrics listener. */
#define CONN_TYPE_METRICS 20

#define CONN_TYPE_MAX_ 21
/* !!!! If _CONN_TYPE_MAX is ever over 31, we must grow the type field in
 * struct connection_t. */

/* Proxy client handshake states */
/* We use a proxy but we haven't even connected to it yet. */
#define PROXY_INFANT 1
/* We use an HTTP proxy and we've sent the CONNECT command. */
#define PROXY_HTTPS_WANT_CONNECT_OK 2
/* We use a SOCKS4 proxy and we've sent the CONNECT command. */
#define PROXY_SOCKS4_WANT_CONNECT_OK 3
/* We use a SOCKS5 proxy and we try to negotiate without
   any authentication . */
#define PROXY_SOCKS5_WANT_AUTH_METHOD_NONE 4
/* We use a SOCKS5 proxy and we try to negotiate with
   Username/Password authentication . */
#define PROXY_SOCKS5_WANT_AUTH_METHOD_RFC1929 5
/* We use a SOCKS5 proxy and we just sent our credentials. */
#define PROXY_SOCKS5_WANT_AUTH_RFC1929_OK 6
/* We use a SOCKS5 proxy and we just sent our CONNECT command. */
#define PROXY_SOCKS5_WANT_CONNECT_OK 7
/* We use an HAPROXY proxy and we just sent the proxy header. */
#define PROXY_HAPROXY_WAIT_FOR_FLUSH 8
/* We use a proxy and we CONNECTed successfully!. */
#define PROXY_CONNECTED 9

/** State for any listener connection. */
#define LISTENER_STATE_READY 0

/**
 * This struct associates an old listener connection to be replaced
 * by new connection described by port configuration. Only used when
 * moving listeners to/from wildcard IP address.
 */
typedef struct
{
  struct connection_t *old_conn; /* Old listener connection to be replaced */
  const struct port_cfg_t *new_port; /* New port configuration */
} listener_replacement_t;

const char *conn_type_to_string(int type);
const char *conn_state_to_string(int type, int state);
int conn_listener_type_supports_af_unix(int type);

const char *connection_describe(const connection_t *conn);
const char *connection_describe_peer(const connection_t *conn);

struct dir_connection_t *dir_connection_new(int socket_family);
struct or_connection_t *or_connection_new(int type, int socket_family);
struct edge_connection_t *edge_connection_new(int type, int socket_family);
struct entry_connection_t *entry_connection_new(int type, int socket_family);
struct control_connection_t *control_connection_new(int socket_family);
struct listener_connection_t *listener_connection_new(int type,
                                                      int socket_family);
struct connection_t *connection_new(int type, int socket_family);
int connection_init_accepted_conn(struct connection_t *conn,
                                const struct listener_connection_t *listener);
void connection_link_connections(struct connection_t *conn_a,
                                 struct connection_t *conn_b);
MOCK_DECL(void,connection_free_,(struct connection_t *conn));
#define connection_free(conn) \
  FREE_AND_NULL(struct connection_t, connection_free_, (conn))
void connection_free_all(void);
void connection_about_to_close_connection(struct connection_t *conn);
void connection_close_immediate(struct connection_t *conn);
void connection_mark_for_close_(struct connection_t *conn,
                                int line, const char *file);
MOCK_DECL(void, connection_mark_for_close_internal_,
          (struct connection_t *conn, int line, const char *file));

#define connection_mark_for_close(c) \
  connection_mark_for_close_((c), __LINE__, SHORT_FILE__)
#define connection_mark_for_close_internal(c) \
  connection_mark_for_close_internal_((c), __LINE__, SHORT_FILE__)

/**
 * Mark 'c' for close, but try to hold it open until all the data is written.
 * Use the _internal versions of connection_mark_for_close; this should be
 * called when you either are sure that if this is an or_connection_t the
 * controlling channel has been notified (e.g. with
 * connection_or_notify_error()), or you actually are the
 * connection_or_close_for_error() or connection_or_close_normally function.
 * For all other cases, use connection_mark_and_flush() instead, which
 * checks for struct or_connection_t properly, instead.  See below.
 */
#define connection_mark_and_flush_internal_(c,line,file)                \
  do {                                                                  \
    struct connection_t *tmp_conn__ = (c);                              \
    connection_mark_for_close_internal_(tmp_conn__, (line), (file));    \
    tmp_conn__->hold_open_until_flushed = 1;                            \
  } while (0)

#define connection_mark_and_flush_internal(c)            \
  connection_mark_and_flush_internal_((c), __LINE__, SHORT_FILE__)

/**
 * Mark 'c' for close, but try to hold it open until all the data is written.
 */
#define connection_mark_and_flush_(c,line,file)                           \
  do {                                                                    \
    struct connection_t *tmp_conn_ = (c);                                 \
    if (tmp_conn_->type == CONN_TYPE_OR) {                                \
      log_warn(LD_CHANNEL | LD_BUG,                                       \
               "Something tried to close (and flush) an or_connection_t"  \
               " without going through channels at %s:%d",                \
               file, line);                                               \
      connection_or_close_for_error(TO_OR_CONN(tmp_conn_), 1);            \
    } else {                                                              \
      connection_mark_and_flush_internal_(c, line, file);                 \
    }                                                                     \
  } while (0)

#define connection_mark_and_flush(c)            \
  connection_mark_and_flush_((c), __LINE__, SHORT_FILE__)

void connection_expire_held_open(void);

int connection_connect(struct connection_t *conn, const char *address,
                       const struct tor_addr_t *addr,
                       uint16_t port, int *socket_error);

#ifdef HAVE_SYS_UN_H

int connection_connect_unix(struct connection_t *conn, const char *socket_path,
                            int *socket_error);

#endif /* defined(HAVE_SYS_UN_H) */

/** Maximum size of information that we can fit into SOCKS5 username
    or password fields. */
#define MAX_SOCKS5_AUTH_FIELD_SIZE 255

/** Total maximum size of information that we can fit into SOCKS5
    username and password fields. */
#define MAX_SOCKS5_AUTH_SIZE_TOTAL 2*MAX_SOCKS5_AUTH_FIELD_SIZE

int connection_proxy_connect(struct connection_t *conn, int type);
int connection_read_proxy_handshake(struct connection_t *conn);
void log_failed_proxy_connection(struct connection_t *conn);
int get_proxy_addrport(struct tor_addr_t *addr, uint16_t *port,
                       int *proxy_type,
                       int *is_pt_out, const struct connection_t *conn);

int retry_all_listeners(struct smartlist_t *new_conns,
                        int close_all_noncontrol);

void connection_mark_all_noncontrol_listeners(void);
void connection_mark_all_noncontrol_connections(void);

ssize_t connection_bucket_write_limit(struct connection_t *conn, time_t now);
bool connection_dir_is_global_write_low(const struct connection_t *conn,
                                        size_t attempt);
void connection_bucket_init(void);
void connection_bucket_adjust(const struct or_options_t *options);
void connection_bucket_refill_all(time_t now,
                                  uint32_t now_ts);
void connection_read_bw_exhausted(struct connection_t *conn,
                                  bool is_global_bw);
void connection_write_bw_exhausted(struct connection_t *conn,
                                   bool is_global_bw);
void connection_consider_empty_read_buckets(struct connection_t *conn);
void connection_consider_empty_write_buckets(struct connection_t *conn);

int connection_handle_read(struct connection_t *conn);

int connection_buf_get_bytes(char *string, size_t len,
                             struct connection_t *conn);
int connection_buf_get_line(struct connection_t *conn, char *data,
                            size_t *data_len);
int connection_fetch_from_buf_http(struct connection_t *conn,
                               char **headers_out, size_t max_headerlen,
                               char **body_out, size_t *body_used,
                               size_t max_bodylen, int force_complete);

int connection_wants_to_flush(struct connection_t *conn);
int connection_outbuf_too_full(struct connection_t *conn);
int connection_handle_write(struct connection_t *conn, int force);
int connection_flush(struct connection_t *conn);
int connection_process_inbuf(struct connection_t *conn, int package_partial);

MOCK_DECL(void, connection_write_to_buf_impl_,
          (const char *string, size_t len, struct connection_t *conn,
           int zlib));
/* DOCDOC connection_write_to_buf */
static void connection_buf_add(const char *string, size_t len,
                                    struct connection_t *conn);
void connection_dir_buf_add(const char *string, size_t len,
                            struct dir_connection_t *dir_conn, int done);
static inline void
connection_buf_add(const char *string, size_t len, struct connection_t *conn)
{
  connection_write_to_buf_impl_(string, len, conn, 0);
}
void connection_buf_add_compress(const char *string, size_t len,
                                 struct dir_connection_t *conn, int done);
void connection_buf_add_buf(struct connection_t *conn, struct buf_t *buf);

size_t connection_get_inbuf_len(const struct connection_t *conn);
size_t connection_get_outbuf_len(const struct connection_t *conn);
struct connection_t *connection_get_by_global_id(uint64_t id);

struct connection_t *connection_get_by_type(int type);
MOCK_DECL(struct connection_t *,connection_get_by_type_nonlinked,(int type));
MOCK_DECL(struct connection_t *,connection_get_by_type_addr_port_purpose,
                                               (int type,
                                                const struct tor_addr_t *addr,
                                                uint16_t port, int purpose));
struct connection_t *connection_get_by_type_state(int type, int state);
struct connection_t *connection_get_by_type_state_rendquery(
                                                     int type, int state,
                                                     const char *rendquery);
struct smartlist_t *connection_list_by_type_state(int type, int state);
struct smartlist_t *connection_list_by_type_purpose(int type, int purpose);
struct smartlist_t *connection_dir_list_by_purpose_and_resource(
                                                  int purpose,
                                                  const char *resource);
struct smartlist_t *connection_dir_list_by_purpose_resource_and_state(
                                                  int purpose,
                                                  const char *resource,
                                                  int state);

#define CONN_LEN_AND_FREE_TEMPLATE(sl) \
  STMT_BEGIN                           \
    int len = smartlist_len(sl);       \
    smartlist_free(sl);                \
    return len;                        \
  STMT_END

/** Return a count of directory connections that are fetching the item
 * described by <b>purpose</b>/<b>resource</b>. */
static inline int
connection_dir_count_by_purpose_and_resource(
                                             int purpose,
                                             const char *resource)
{
  struct smartlist_t *conns = connection_dir_list_by_purpose_and_resource(
                                                                   purpose,
                                                                   resource);
  CONN_LEN_AND_FREE_TEMPLATE(conns);
}

/** Return a count of directory connections that are fetching the item
 * described by <b>purpose</b>/<b>resource</b>/<b>state</b>. */
static inline int
connection_dir_count_by_purpose_resource_and_state(
                                                   int purpose,
                                                   const char *resource,
                                                   int state)
{
  struct smartlist_t *conns =
    connection_dir_list_by_purpose_resource_and_state(
                                                      purpose,
                                                      resource,
                                                      state);
  CONN_LEN_AND_FREE_TEMPLATE(conns);
}

#undef CONN_LEN_AND_FREE_TEMPLATE

int any_other_active_or_conns(const struct or_connection_t *this_conn);

/* || 0 is for -Wparentheses-equality (-Wall?) appeasement under clang */
#define connection_speaks_cells(conn) (((conn)->type == CONN_TYPE_OR) || 0)
int connection_is_listener(struct connection_t *conn);
int connection_state_is_open(struct connection_t *conn);
int connection_state_is_connecting(struct connection_t *conn);

char *alloc_http_authenticator(const char *authenticator);

void assert_connection_ok(struct connection_t *conn, time_t now);
int connection_or_nonopen_was_started_here(struct or_connection_t *conn);
void connection_dump_buffer_mem_stats(int severity);

MOCK_DECL(void, clock_skew_warning,
          (const struct connection_t *conn, long apparent_skew, int trusted,
           log_domain_mask_t domain, const char *received,
           const char *source));

int connection_is_moribund(struct connection_t *conn);
void connection_check_oos(int n_socks, int failed);

/** Execute the statement <b>stmt</b>, which may log events concerning the
 * connection <b>conn</b>.  To prevent infinite loops, disable log messages
 * being sent to controllers if <b>conn</b> is a control connection.
 *
 * Stmt must not contain any return or goto statements.
 */
#define CONN_LOG_PROTECT(conn, stmt)                                    \
  STMT_BEGIN                                                            \
    int _log_conn_is_control;                                           \
    tor_assert(conn);                                                   \
    _log_conn_is_control = (conn->type == CONN_TYPE_CONTROL);           \
    if (_log_conn_is_control)                                           \
      disable_control_logging();                                        \
  STMT_BEGIN stmt; STMT_END;                                            \
    if (_log_conn_is_control)                                           \
      enable_control_logging();                                         \
  STMT_END

#ifdef CONNECTION_PRIVATE
STATIC void connection_free_minimal(struct connection_t *conn);

/* Used only by connection.c and test*.c */
MOCK_DECL(STATIC int,connection_connect_sockaddr,
                                            (struct connection_t *conn,
                                             const struct sockaddr *sa,
                                             socklen_t sa_len,
                                             const struct sockaddr *bindaddr,
                                             socklen_t bindaddr_len,
                                             int *socket_error));
MOCK_DECL(STATIC void, kill_conn_list_for_oos, (struct smartlist_t *conns));
MOCK_DECL(STATIC struct smartlist_t *, pick_oos_victims, (int n));

#endif /* defined(CONNECTION_PRIVATE) */

#endif /* !defined(TOR_CONNECTION_H) */
