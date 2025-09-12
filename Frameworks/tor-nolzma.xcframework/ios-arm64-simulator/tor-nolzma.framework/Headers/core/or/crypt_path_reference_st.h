/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file crypt_path_reference_st.h
 * @brief reference-counting structure for crypt_path_t
 **/

#ifndef CRYPT_PATH_REFERENCE_ST_H
#define CRYPT_PATH_REFERENCE_ST_H

/** A reference-counted pointer to a crypt_path_t, used only to share
 * the final rendezvous cpath to be used on a service-side rendezvous
 * circuit among multiple circuits built in parallel to the same
 * destination rendezvous point. */
struct crypt_path_reference_t {
  /** The reference count. */
  unsigned int refcount;
  /** The pointer.  Set to NULL when the crypt_path_t is put into use
   * on an opened rendezvous circuit. */
  crypt_path_t *cpath;
};

#endif /* !defined(CRYPT_PATH_REFERENCE_ST_H) */
