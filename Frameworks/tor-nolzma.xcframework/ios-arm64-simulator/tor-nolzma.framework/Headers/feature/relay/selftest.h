/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file selftest.h
 * \brief Header file for selftest.c.
 **/

#ifndef TOR_SELFTEST_H
#define TOR_SELFTEST_H

#ifdef HAVE_MODULE_RELAY

struct or_options_t;
#define router_all_orports_seem_reachable(opts) \
  router_orport_seems_reachable((opts),0)
int router_orport_seems_reachable(
                                         const struct or_options_t *options,
                                         int family);
int router_dirport_seems_reachable(
                                         const struct or_options_t *options);

void router_do_reachability_checks(void);
void router_perform_bandwidth_test(int num_circs, time_t now);

void router_orport_found_reachable(int family);

void router_reset_reachability(void);

#else /* !defined(HAVE_MODULE_RELAY) */

#define router_all_orports_seem_reachable(opts)     \
  ((void)(opts), 0)
#define router_orport_seems_reachable(opts, fam)  \
  ((void)(opts), (void)(fam), 0)
#define router_dirport_seems_reachable(opts) \
  ((void)(opts), 0)

static inline void
router_do_reachability_checks(void)
{
  tor_assert_nonfatal_unreached();
}
static inline void
router_perform_bandwidth_test(int num_circs, time_t now)
{
  (void)num_circs;
  (void)now;
  tor_assert_nonfatal_unreached();
}
static inline int
inform_testing_reachability(const tor_addr_t *addr, uint16_t port)
{
  (void) addr;
  (void) port;
  tor_assert_nonfatal_unreached();
  return 0;
}

#define router_orport_found_reachable() \
  STMT_NIL

#define router_reset_reachability() \
  STMT_NIL

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_SELFTEST_H) */
