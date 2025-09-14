/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file tor_version_st.h
 * @brief Parsed Tor version structure.
 **/

#ifndef TOR_VERSION_ST_H
#define TOR_VERSION_ST_H

#define MAX_STATUS_TAG_LEN 32
/** Structure to hold parsed Tor versions.  This is a little messier
 * than we would like it to be, because we changed version schemes with 0.1.0.
 *
 * See version-spec.txt for the whole business.
 */
struct tor_version_t {
  int major;
  int minor;
  int micro;
  /** Release status.  For version in the post-0.1 format, this is always
   * VER_RELEASE. */
  enum { VER_PRE=0, VER_RC=1, VER_RELEASE=2, } status;
  int patchlevel;
  char status_tag[MAX_STATUS_TAG_LEN];
  int svn_revision;

  int git_tag_len;
  char git_tag[DIGEST_LEN];
};

#endif /* !defined(TOR_VERSION_ST_H) */
