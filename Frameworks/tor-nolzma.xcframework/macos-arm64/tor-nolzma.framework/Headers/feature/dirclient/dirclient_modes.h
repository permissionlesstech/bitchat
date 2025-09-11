/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dirclient_modes.h
 * @brief Header for feature/dirclient/dirclient_modes.c
 **/

#ifndef TOR_FEATURE_DIRCLIENT_DIRCLIENT_MODES_H
#define TOR_FEATURE_DIRCLIENT_DIRCLIENT_MODES_H

struct or_options_t;

int dirclient_must_use_begindir(const or_options_t *options);
int dirclient_fetches_from_authorities(const struct or_options_t *options);
int dirclient_fetches_dir_info_early(const struct or_options_t *options);
int dirclient_fetches_dir_info_later(const struct or_options_t *options);
int dirclient_too_idle_to_fetch_descriptors(const struct or_options_t *options,
                                            time_t now);

#endif /* !defined(TOR_FEATURE_DIRCLIENT_DIRCLIENT_MODES_H) */
