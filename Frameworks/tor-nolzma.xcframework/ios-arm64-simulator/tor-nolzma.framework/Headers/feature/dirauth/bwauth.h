/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file bwauth.h
 * \brief Header file for bwauth.c
 **/

#ifndef TOR_BWAUTH_H
#define TOR_BWAUTH_H

/** Maximum allowable length of bandwidth headers in a bandwidth file */
#define MAX_BW_FILE_HEADER_COUNT_IN_VOTE 50

/** Terminatore that separates bandwidth file headers from bandwidth file
 * relay lines */
#define BW_FILE_HEADERS_TERMINATOR "=====\n"

int dirserv_read_measured_bandwidths(const char *from_file,
                                     smartlist_t *routerstatuses,
                                     smartlist_t *bw_file_headers,
                                     uint8_t *digest_out);
int dirserv_query_measured_bw_cache_kb(const char *node_id,
                                       long *bw_out,
                                       time_t *as_of_out);
void dirserv_clear_measured_bw_cache(void);
int dirserv_has_measured_bw(const char *node_id);
int dirserv_get_measured_bw_cache_size(void);
void dirserv_count_measured_bws(const smartlist_t *routers);
int dirserv_get_last_n_measured_bws(void);

uint32_t dirserv_get_credible_bandwidth_kb(const routerinfo_t *ri);

#ifdef BWAUTH_PRIVATE
typedef struct measured_bw_line_t {
  char node_id[DIGEST_LEN];
  char node_hex[MAX_HEX_NICKNAME_LEN+1];
  long int bw_kb;
} measured_bw_line_t;

/* Put the MAX_MEASUREMENT_AGE #define here so unit tests can see it */
#define MAX_MEASUREMENT_AGE (3*24*60*60) /* 3 days */

STATIC int measured_bw_line_parse(measured_bw_line_t *out, const char *line,
                                  int line_is_after_headers);

STATIC int measured_bw_line_apply(measured_bw_line_t *parsed_line,
                           smartlist_t *routerstatuses);

STATIC void dirserv_cache_measured_bw(const measured_bw_line_t *parsed_line,
                               time_t as_of);
STATIC void dirserv_expire_measured_bw_cache(time_t now);
#endif /* defined(BWAUTH_PRIVATE) */

#endif /* !defined(TOR_BWAUTH_H) */
