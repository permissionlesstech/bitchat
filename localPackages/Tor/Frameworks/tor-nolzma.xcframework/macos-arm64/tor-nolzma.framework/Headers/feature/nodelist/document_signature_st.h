/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file document_signature_st.h
 * @brief Authority signature structure
 **/

#ifndef DOCUMENT_SIGNATURE_ST_H
#define DOCUMENT_SIGNATURE_ST_H

/** A signature of some document by an authority. */
struct document_signature_t {
  /** Declared SHA-1 digest of this voter's identity key */
  char identity_digest[DIGEST_LEN];
  /** Declared SHA-1 digest of signing key used by this voter. */
  char signing_key_digest[DIGEST_LEN];
  /** Algorithm used to compute the digest of the document. */
  digest_algorithm_t alg;
  /** Signature of the signed thing. */
  char *signature;
  /** Length of <b>signature</b> */
  int signature_len;
  unsigned int bad_signature : 1; /**< Set to true if we've tried to verify
                                   * the sig, and we know it's bad. */
  unsigned int good_signature : 1; /**< Set to true if we've verified the sig
                                     * as good. */
};

#endif /* !defined(DOCUMENT_SIGNATURE_ST_H) */
