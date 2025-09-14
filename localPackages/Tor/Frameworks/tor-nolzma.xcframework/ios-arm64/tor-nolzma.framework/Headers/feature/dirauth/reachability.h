/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file reachability.h
 * \brief Header file for reachability.c.
 **/

#ifndef TOR_REACHABILITY_H
#define TOR_REACHABILITY_H

/** What fraction (1 over this number) of the relay ID space do we
 * (as a directory authority) launch connections to at each reachability
 * test? */
#define REACHABILITY_MODULO_PER_TEST 128

/** How often (in seconds) do we launch reachability tests? */
#define REACHABILITY_TEST_INTERVAL 10

/** How many seconds apart are the reachability tests for a given relay? */
#define REACHABILITY_TEST_CYCLE_PERIOD \
  (REACHABILITY_TEST_INTERVAL*REACHABILITY_MODULO_PER_TEST)

#ifdef HAVE_MODULE_DIRAUTH
void dirserv_single_reachability_test(time_t now, routerinfo_t *router);
void dirserv_test_reachability(time_t now);

int dirserv_should_launch_reachability_test(const routerinfo_t *ri,
                                            const routerinfo_t *ri_old);
void dirserv_orconn_tls_done(const tor_addr_t *addr,
                             uint16_t or_port,
                             const char *digest_rcvd,
                             const struct ed25519_public_key_t *ed_id_rcvd);
#else /* !defined(HAVE_MODULE_DIRAUTH) */
#define dirserv_single_reachability_test(now, router) \
  (((void)(now)),((void)(router)))
#define dirserv_test_reachability(now) \
  (((void)(now)))

#define dirserv_should_launch_reachability_test(ri, ri_old) \
  (((void)(ri)),((void)(ri_old)),0)
#define dirserv_orconn_tls_done(addr, or_port, digest_rcvd, ed_id_rcvd) \
  (((void)(addr)),((void)(or_port)),((void)(digest_rcvd)), \
   ((void)(ed_id_rcvd)))
#endif /* defined(HAVE_MODULE_DIRAUTH) */

#endif /* !defined(TOR_REACHABILITY_H) */
