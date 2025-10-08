/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file versions.h
 * \brief Header file for versions.c.
 **/

#ifndef TOR_VERSIONS_H
#define TOR_VERSIONS_H

/** Possible statuses of a version of Tor, given opinions from the directory
 * servers. */
typedef enum version_status_t {
  VS_RECOMMENDED=0, /**< This version is listed as recommended. */
  VS_OLD=1, /**< This version is older than any recommended version. */
  VS_NEW=2, /**< This version is newer than any recommended version. */
  VS_NEW_IN_SERIES=3, /**< This version is newer than any recommended version
                       * in its series, but later recommended versions exist.
                       */
  VS_UNRECOMMENDED=4, /**< This version is not recommended (general case). */
  VS_EMPTY=5, /**< The version list was empty; no agreed-on versions. */
  VS_UNKNOWN, /**< We have no idea. */
} version_status_t;

time_t tor_get_approx_release_date(void);

version_status_t tor_version_is_obsolete(const char *myversion,
                                         const char *versionlist);
int tor_version_parse_platform(const char *platform,
                               tor_version_t *version_out,
                               int strict);
int tor_version_as_new_as(const char *platform, const char *cutoff);
int tor_version_parse(const char *s, tor_version_t *out);
int tor_version_compare(tor_version_t *a, tor_version_t *b);
int tor_version_same_series(tor_version_t *a, tor_version_t *b);
void sort_version_list(smartlist_t *lst, int remove_duplicates);

void summarize_protover_flags(protover_summary_flags_t *out,
                              const char *protocols,
                              const char *version);

void protover_summary_cache_free_all(void);

#endif /* !defined(TOR_VERSIONS_H) */
