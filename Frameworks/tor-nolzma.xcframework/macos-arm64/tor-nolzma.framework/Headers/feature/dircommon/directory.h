/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file directory.h
 * \brief Header file for directory.c.
 **/

#ifndef TOR_DIRECTORY_H
#define TOR_DIRECTORY_H

dir_connection_t *TO_DIR_CONN(connection_t *c);
const dir_connection_t *CONST_TO_DIR_CONN(const connection_t *c);

#define DIR_CONN_STATE_MIN_ 1
/** State for connection to directory server: waiting for connect(). */
#define DIR_CONN_STATE_CONNECTING 1
/** State for connection to directory server: sending HTTP request. */
#define DIR_CONN_STATE_CLIENT_SENDING 2
/** State for connection to directory server: reading HTTP response. */
#define DIR_CONN_STATE_CLIENT_READING 3
/** State for connection to directory server: happy and finished. */
#define DIR_CONN_STATE_CLIENT_FINISHED 4
/** State for connection at directory server: waiting for HTTP request. */
#define DIR_CONN_STATE_SERVER_COMMAND_WAIT 5
/** State for connection at directory server: sending HTTP response. */
#define DIR_CONN_STATE_SERVER_WRITING 6
#define DIR_CONN_STATE_MAX_ 6

#define DIR_PURPOSE_MIN_ 6
/** A connection to a directory server: download one or more server
 * descriptors. */
#define DIR_PURPOSE_FETCH_SERVERDESC 6
/** A connection to a directory server: download one or more extra-info
 * documents. */
#define DIR_PURPOSE_FETCH_EXTRAINFO 7
/** A connection to a directory server: upload a server descriptor. */
#define DIR_PURPOSE_UPLOAD_DIR 8
/** A connection to a directory server: upload a v3 networkstatus vote. */
#define DIR_PURPOSE_UPLOAD_VOTE 10
/** A connection to a directory server: upload a v3 consensus signature */
#define DIR_PURPOSE_UPLOAD_SIGNATURES 11
/** A connection to a directory server: download one or more v3 networkstatus
 * votes. */
#define DIR_PURPOSE_FETCH_STATUS_VOTE 12
/** A connection to a directory server: download a v3 detached signatures
 * object for a consensus. */
#define DIR_PURPOSE_FETCH_DETACHED_SIGNATURES 13
/** A connection to a directory server: download a v3 networkstatus
 * consensus. */
#define DIR_PURPOSE_FETCH_CONSENSUS 14
/** A connection to a directory server: download one or more directory
 * authority certificates. */
#define DIR_PURPOSE_FETCH_CERTIFICATE 15

/** Purpose for connection at a directory server. */
#define DIR_PURPOSE_SERVER 16

/** Value 17 and 18 were onion service v2 purposes. */

/** A connection to a directory server: download a microdescriptor. */
#define DIR_PURPOSE_FETCH_MICRODESC 19
/** A connection to a hidden service directory: upload a v3 descriptor. */
#define DIR_PURPOSE_UPLOAD_HSDESC 20
/** A connection to a hidden service directory: fetch a v3 descriptor. */
#define DIR_PURPOSE_FETCH_HSDESC 21
/** A connection to a directory server: set after a hidden service descriptor
 * is downloaded. */
#define DIR_PURPOSE_HAS_FETCHED_HSDESC 22
#define DIR_PURPOSE_MAX_ 22

/** True iff <b>p</b> is a purpose corresponding to uploading
 * data to a directory server. */
#define DIR_PURPOSE_IS_UPLOAD(p)                \
  ((p)==DIR_PURPOSE_UPLOAD_DIR ||               \
   (p)==DIR_PURPOSE_UPLOAD_VOTE ||              \
   (p)==DIR_PURPOSE_UPLOAD_SIGNATURES ||        \
   (p)==DIR_PURPOSE_UPLOAD_HSDESC)

/** True iff p is a purpose corresponding to onion service that is either
 * uploading or fetching actions. */
#define DIR_PURPOSE_IS_HS(p)          \
  ((p) == DIR_PURPOSE_FETCH_HSDESC || \
   (p) == DIR_PURPOSE_UPLOAD_HSDESC)

enum compress_method_t;
int parse_http_response(const char *headers, int *code, time_t *date,
                        enum compress_method_t *compression, char **response);
int parse_http_command(const char *headers,
                       char **command_out, char **url_out);
char *http_get_header(const char *headers, const char *which);

int connection_dir_is_encrypted(const dir_connection_t *conn);
bool connection_dir_is_anonymous(const dir_connection_t *conn);
int connection_dir_reached_eof(dir_connection_t *conn);
int connection_dir_process_inbuf(dir_connection_t *conn);
int connection_dir_finished_flushing(dir_connection_t *conn);
int connection_dir_finished_connecting(dir_connection_t *conn);
void connection_dir_about_to_close(dir_connection_t *dir_conn);

#define DSR_HEX       (1<<0)
#define DSR_BASE64    (1<<1)
#define DSR_DIGEST256 (1<<2)
#define DSR_SORT_UNIQ (1<<3)
int dir_split_resource_into_fingerprints(const char *resource,
                                     smartlist_t *fp_out, int *compressed_out,
                                     int flags);
int dir_split_resource_into_fingerprint_pairs(const char *res,
                                              smartlist_t *pairs_out);
char *directory_dump_request_log(void);
void note_request(const char *key, size_t bytes);

int purpose_needs_anonymity(uint8_t dir_purpose, uint8_t router_purpose,
                            const char *resource);

char *authdir_type_to_string(dirinfo_type_t auth);

#define X_ADDRESS_HEADER "X-Your-Address-Is: "
#define X_OR_DIFF_FROM_CONSENSUS_HEADER "X-Or-Diff-From-Consensus: "

#endif /* !defined(TOR_DIRECTORY_H) */
