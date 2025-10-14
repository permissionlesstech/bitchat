/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file addr_policy_st.h
 * @brief Address policy structures.
 **/

#ifndef TOR_ADDR_POLICY_ST_H
#define TOR_ADDR_POLICY_ST_H

#include "lib/cc/torint.h"
#include "lib/net/address.h"

/** What action type does an address policy indicate: accept or reject? */
typedef enum {
  ADDR_POLICY_ACCEPT=1,
  ADDR_POLICY_REJECT=2,
} addr_policy_action_t;
#define addr_policy_action_bitfield_t ENUM_BF(addr_policy_action_t)

/** A reference-counted address policy rule. */
struct addr_policy_t {
  int refcnt; /**< Reference count */
  /** What to do when the policy matches.*/
  addr_policy_action_bitfield_t policy_type:2;
  unsigned int is_private:1; /**< True iff this is the pseudo-address,
                              * "private". */
  unsigned int is_canonical:1; /**< True iff this policy is the canonical
                                * copy (stored in a hash table to avoid
                                * duplication of common policies) */
  maskbits_t maskbits; /**< Accept/reject all addresses <b>a</b> such that the
                 * first <b>maskbits</b> bits of <b>a</b> match
                 * <b>addr</b>. */
  /** Base address to accept or reject.
   *
   * Note that wildcards are treated
   * differently depending on address family. An AF_UNSPEC address means
   * "All addresses, IPv4 or IPv6." An AF_INET address with maskbits==0 means
   * "All IPv4 addresses" and an AF_INET6 address with maskbits == 0 means
   * "All IPv6 addresses".
  **/
  tor_addr_t addr;
  uint16_t prt_min; /**< Lowest port number to accept/reject. */
  uint16_t prt_max; /**< Highest port number to accept/reject. */
};

#endif /* !defined(TOR_ADDR_POLICY_ST_H) */
