/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file metrics_sys.h
 * @brief Header for feature/metrics/metrics_sys.c
 **/

#ifndef TOR_FEATURE_METRICS_METRICS_SYS_H
#define TOR_FEATURE_METRICS_METRICS_SYS_H

extern const struct subsys_fns_t sys_metrics;

/**
 * Subsystem level for the metrics system.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define METRICS_SUBSYS_LEVEL (99)

#endif /* !defined(TOR_FEATURE_METRICS_METRICS_SYS_H) */
