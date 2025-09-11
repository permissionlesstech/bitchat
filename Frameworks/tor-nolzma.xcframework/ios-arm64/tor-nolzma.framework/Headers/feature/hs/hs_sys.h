/*  Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file hs_sys.h
 * @brief Header for feature/hs/hs_sys.c
 **/

#ifndef TOR_FEATURE_HS_HS_SYS_H
#define TOR_FEATURE_HS_HS_SYS_H

extern const struct subsys_fns_t sys_hs;

/**
 * Subsystem level for the metrics system.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define HS_SUBSYS_LEVEL (51)

#endif /* !defined(TOR_FEATURE_HS_HS_SYS_H) */
