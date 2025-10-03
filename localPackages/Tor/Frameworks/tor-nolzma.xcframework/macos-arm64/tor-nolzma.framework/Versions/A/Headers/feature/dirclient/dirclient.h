/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dirclient.h
 * \brief Header file for dirclient.c.
 **/

#ifndef TOR_DIRCLIENT_H
#define TOR_DIRCLIENT_H

#include "feature/hs/hs_ident.h"

void dirclient_dump_total_dls(void);

int directories_have_accepted_server_descriptor(void);
void directory_post_to_dirservers(uint8_t dir_purpose, uint8_t router_purpose,
                                  dirinfo_type_t type, const char *payload,
                                  size_t payload_len, size_t extrainfo_len);
MOCK_DECL(void, directory_get_from_dirserver, (
                          uint8_t dir_purpose,
                          uint8_t router_purpose,
                          const char *resource,
                          int pds_flags,
                          download_want_authority_t want_authority));
void directory_get_from_all_authorities(uint8_t dir_purpose,
                                        uint8_t router_purpose,
                                        const char *resource);

/** Enumeration of ways to connect to a directory server */
typedef enum {
  /** Default: connect over a one-hop Tor circuit. Relays fall back to direct
   * DirPort connections, clients, onion services, and bridges do not */
  DIRIND_ONEHOP=0,
  /** Connect over a multi-hop anonymizing Tor circuit */
  DIRIND_ANONYMOUS=1,
  /** Connect to the DirPort directly */
  DIRIND_DIRECT_CONN,
  /** Connect over a multi-hop anonymizing Tor circuit to our dirport */
  DIRIND_ANON_DIRPORT,
} dir_indirection_t;

/**
 * A directory_request_t describes the information about a directory request
 * at the client side.  It describes what we're going to ask for, which
 * directory we're going to ask for it, how we're going to contact that
 * directory, and (in some cases) what to do with it when we're done.
 */
typedef struct directory_request_t directory_request_t;
directory_request_t *directory_request_new(uint8_t dir_purpose);
void directory_request_free_(directory_request_t *req);
#define directory_request_free(req) \
  FREE_AND_NULL(directory_request_t, directory_request_free_, (req))
void directory_request_set_or_addr_port(directory_request_t *req,
                                        const tor_addr_port_t *p);
void directory_request_set_dir_addr_port(directory_request_t *req,
                                         const tor_addr_port_t *p);
void directory_request_set_directory_id_digest(directory_request_t *req,
                                               const char *digest);
struct circuit_guard_state_t;
void directory_request_set_guard_state(directory_request_t *req,
                                       struct circuit_guard_state_t *state);
void directory_request_set_router_purpose(directory_request_t *req,
                                          uint8_t router_purpose);
void directory_request_set_indirection(directory_request_t *req,
                                       dir_indirection_t indirection);
void directory_request_set_resource(directory_request_t *req,
                                    const char *resource);
void directory_request_set_payload(directory_request_t *req,
                                   const char *payload,
                                   size_t payload_len);
void directory_request_set_if_modified_since(directory_request_t *req,
                                             time_t if_modified_since);
void directory_request_upload_set_hs_ident(directory_request_t *req,
                                           const hs_ident_dir_conn_t *ident);
void directory_request_fetch_set_hs_ident(directory_request_t *req,
                                          const hs_ident_dir_conn_t *ident);

void directory_request_set_routerstatus(directory_request_t *req,
                                        const routerstatus_t *rs);
void directory_request_add_header(directory_request_t *req,
                                  const char *key,
                                  const char *val);
MOCK_DECL(void, directory_initiate_request, (directory_request_t *request));

int router_supports_extrainfo(const char *identity_digest, int is_authority);

void connection_dir_client_request_failed(dir_connection_t *conn);
void connection_dir_client_refetch_hsdesc_if_needed(
                                          dir_connection_t *dir_conn);

#ifdef DIRCLIENT_PRIVATE
struct directory_request_t {
  /**
   * These fields specify which directory we're contacting.  Routerstatus,
   * if present, overrides the other fields.
   *
   * @{ */
  tor_addr_port_t or_addr_port;
  tor_addr_port_t dir_addr_port;
  char digest[DIGEST_LEN];

  const routerstatus_t *routerstatus;
  /** @} */
  /** One of DIR_PURPOSE_* other than DIR_PURPOSE_SERVER. Describes what
   * kind of operation we'll be doing (upload/download), and of what kind
   * of document. */
  uint8_t dir_purpose;
  /** One of ROUTER_PURPOSE_*; used for uploads and downloads of routerinfo
   * and extrainfo docs.  */
  uint8_t router_purpose;
  /** Enum: determines whether to anonymize, and whether to use dirport or
   * orport. */
  dir_indirection_t indirection;
  /** Alias to the variable part of the URL for this request */
  const char *resource;
  /** Alias to the payload to upload (if any) */
  const char *payload;
  /** Number of bytes to upload from payload</b> */
  size_t payload_len;
  /** Value to send in an if-modified-since header, or 0 for none. */
  time_t if_modified_since;
  /** Extra headers to append to the request */
  struct config_line_t *additional_headers;
  /** Hidden-service-specific information for v3+. */
  const hs_ident_dir_conn_t *hs_ident;
  /** Used internally to directory.c: gets informed when the attempt to
   * connect to the directory succeeds or fails, if that attempt bears on the
   * directory's usability as a directory guard. */
  struct circuit_guard_state_t *guard_state;
};

/** A structure to hold arguments passed into each directory response
 * handler */
typedef struct response_handler_args_t {
  int status_code;
  const char *reason;
  const char *body;
  size_t body_len;
  const char *headers;
} response_handler_args_t;

enum compress_method_t;
STATIC int allowed_anonymous_connection_compression_method(
                                               enum compress_method_t);
STATIC void warn_disallowed_anonymous_compression_method(
                                               enum compress_method_t);

STATIC int should_use_directory_guards(const or_options_t *options);
STATIC char *accept_encoding_header(void);
STATIC const char *dir_conn_purpose_to_string(int purpose);

STATIC int handle_response_fetch_hsdesc_v3(dir_connection_t *conn,
                                          const response_handler_args_t *args);
STATIC int handle_response_fetch_microdesc(dir_connection_t *conn,
                                 const response_handler_args_t *args);

STATIC int handle_response_fetch_consensus(dir_connection_t *conn,
                                         const response_handler_args_t *args);

STATIC dirinfo_type_t dir_fetch_type(int dir_purpose, int router_purpose,
                                     const char *resource);
#endif /* defined(DIRCLIENT_PRIVATE) */

#endif /* !defined(TOR_DIRCLIENT_H) */
