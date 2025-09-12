/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file country.h
 * @brief Country type for geoip.
 **/

#ifndef TOR_COUNTRY_H
#define TOR_COUNTRY_H

#include "lib/cc/torint.h"
/** A signed integer representing a country code. */
typedef int16_t country_t;

/** Maximum value for country_t. */
#define COUNTRY_MAX INT16_MAX

#endif /* !defined(TOR_COUNTRY_H) */
