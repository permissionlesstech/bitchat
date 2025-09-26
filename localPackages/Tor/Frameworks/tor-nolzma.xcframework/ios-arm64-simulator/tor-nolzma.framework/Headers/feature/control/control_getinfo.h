/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control.h
 * \brief Header file for control.c.
 **/

#ifndef TOR_CONTROL_GETINFO_H
#define TOR_CONTROL_GETINFO_H

struct control_cmd_syntax_t;
struct control_cmd_args_t;
extern const struct control_cmd_syntax_t getinfo_syntax;

int handle_control_getinfo(control_connection_t *conn,
                           const struct control_cmd_args_t *args);

#ifdef CONTROL_GETINFO_PRIVATE
STATIC int getinfo_helper_onions(
    control_connection_t *control_conn,
    const char *question,
    char **answer,
    const char **errmsg);
STATIC void getinfo_helper_downloads_networkstatus(
    const char *flavor,
    download_status_t **dl_to_emit,
    const char **errmsg);
STATIC void getinfo_helper_downloads_cert(
    const char *fp_sk_req,
    download_status_t **dl_to_emit,
    smartlist_t **digest_list,
    const char **errmsg);
STATIC void getinfo_helper_downloads_desc(
    const char *desc_req,
    download_status_t **dl_to_emit,
    smartlist_t **digest_list,
    const char **errmsg);
STATIC void getinfo_helper_downloads_bridge(
    const char *bridge_req,
    download_status_t **dl_to_emit,
    smartlist_t **digest_list,
    const char **errmsg);
STATIC int getinfo_helper_downloads(
    control_connection_t *control_conn,
    const char *question, char **answer,
    const char **errmsg);
STATIC int getinfo_helper_current_consensus(
    consensus_flavor_t flavor,
    char **answer,
    const char **errmsg);
STATIC int getinfo_helper_dir(
    control_connection_t *control_conn,
    const char *question, char **answer,
    const char **errmsg);
STATIC int getinfo_helper_current_time(
    control_connection_t *control_conn,
    const char *question, char **answer,
    const char **errmsg);
STATIC int getinfo_helper_rephist(
    control_connection_t *control_conn,
    const char *question, char **answer,
    const char **errmsg);
#endif /* defined(CONTROL_GETINFO_PRIVATE) */

#endif /* !defined(TOR_CONTROL_GETINFO_H) */
