/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dirauth_options_st.h
 * @brief Structure hs_opts_t to hold options for a single hidden service.
 **/

#ifndef TOR_FEATURE_HS_HS_OPTS_ST_H
#define TOR_FEATURE_HS_HS_OPTS_ST_H

#include "lib/conf/confdecl.h"
#define CONF_CONTEXT STRUCT
#include "feature/hs/hs_options.inc"
#undef CONF_CONTEXT

/**
 * An hs_opts_t holds the parsed options for a single HS configuration
 * section.
 *
 * This name ends with 'opts' instead of 'options' to signal that it is not
 * handled directly by the or_options_t configuration manager, but that
 * first we partition the "HiddenService*" options by section.
 **/
typedef struct hs_opts_t hs_opts_t;

#endif /* !defined(TOR_FEATURE_HS_HS_OPTS_ST_H) */
