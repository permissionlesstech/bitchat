/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file extrainfo_st.h
 * @brief A relay's extra-info structure.
 **/

#ifndef EXTRAINFO_ST_H
#define EXTRAINFO_ST_H

#include "feature/nodelist/signed_descriptor_st.h"

/** Information needed to keep and cache a signed extra-info document. */
struct extrainfo_t {
  signed_descriptor_t cache_info;
  /** SHA256 digest of this document */
  uint8_t digest256[DIGEST256_LEN];
  /** The router's nickname. */
  char nickname[MAX_NICKNAME_LEN+1];
  /** True iff we found the right key for this extra-info, verified the
   * signature, and found it to be bad. */
  unsigned int bad_sig : 1;
  /** If present, we didn't have the right key to verify this extra-info,
   * so this is a copy of the signature in the document. */
  char *pending_sig;
  /** Length of pending_sig. */
  size_t pending_sig_len;
};

#endif /* !defined(EXTRAINFO_ST_H) */
