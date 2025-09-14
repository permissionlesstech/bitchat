/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control_auth.h
 * \brief Header file for control_auth.c.
 **/

#ifndef TOR_CONTROL_AUTH_H
#define TOR_CONTROL_AUTH_H

struct control_cmd_args_t;
struct control_cmd_syntax_t;

int init_control_cookie_authentication(int enabled);
char *get_controller_cookie_file_name(void);
struct config_line_t;
smartlist_t *decode_hashed_passwords(struct config_line_t *passwords);

int handle_control_authchallenge(control_connection_t *conn,
                                 const struct control_cmd_args_t *args);
int handle_control_authenticate(control_connection_t *conn,
                                const struct control_cmd_args_t *args);
void control_auth_free_all(void);

extern const struct control_cmd_syntax_t authchallenge_syntax;
extern const struct control_cmd_syntax_t authenticate_syntax;

#endif /* !defined(TOR_CONTROL_AUTH_H) */
