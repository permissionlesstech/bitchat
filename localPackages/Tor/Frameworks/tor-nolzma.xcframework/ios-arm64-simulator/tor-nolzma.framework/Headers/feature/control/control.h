/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control.h
 * \brief Header file for control.c.
 **/

#ifndef TOR_CONTROL_H
#define TOR_CONTROL_H

control_connection_t *TO_CONTROL_CONN(connection_t *);
const control_connection_t *CONST_TO_CONTROL_CONN(const connection_t *);

#define CONTROL_CONN_STATE_MIN_ 1
/** State for a control connection: Authenticated and accepting v1 commands. */
#define CONTROL_CONN_STATE_OPEN 1
/** State for a control connection: Waiting for authentication; speaking
 * protocol v1. */
#define CONTROL_CONN_STATE_NEEDAUTH 2
#define CONTROL_CONN_STATE_MAX_ 2

void control_ports_write_to_file(void);

/** Log information about the connection <b>conn</b>, protecting it as with
 * CONN_LOG_PROTECT. Example:
 *
 * LOG_FN_CONN(conn, (LOG_DEBUG, "Socket %d wants to write", conn->s));
 **/
#define LOG_FN_CONN(conn, args)                 \
  CONN_LOG_PROTECT(conn, log_fn args)

#define CC_LOCAL_FD_IS_OWNER (1u<<0)
#define CC_LOCAL_FD_IS_AUTHENTICATED (1u<<1)
int control_connection_add_local_fd(tor_socket_t sock, unsigned flags);

int connection_control_finished_flushing(control_connection_t *conn);
int connection_control_reached_eof(control_connection_t *conn);
void connection_control_closed(control_connection_t *conn);

int connection_control_process_inbuf(control_connection_t *conn);

void disable_control_logging(void);
void enable_control_logging(void);

void monitor_owning_controller_process(const char *process_spec);

const char *rend_auth_type_to_string(rend_auth_type_t auth_type);
void control_free_all(void);

#ifdef CONTROL_MODULE_PRIVATE
struct signal_name_t {
  int sig;
  const char *signal_name;
};
extern const struct signal_name_t signal_table[];
int get_cached_network_liveness(void);
void set_cached_network_liveness(int liveness);
#endif /* defined(CONTROL_MODULE_PRIVATE) */

#ifdef CONTROL_PRIVATE
STATIC char *control_split_incoming_command(char *incoming_cmd,
                                            size_t *data_len,
                                            char **current_cmd_out);
#endif

#endif /* !defined(TOR_CONTROL_H) */
