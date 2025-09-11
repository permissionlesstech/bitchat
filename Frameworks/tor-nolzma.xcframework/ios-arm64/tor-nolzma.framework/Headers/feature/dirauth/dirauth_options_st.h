/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dirauth_options_st.h
 * @brief Structure dirauth_options_t to hold directory authority options.
 **/

#ifndef TOR_FEATURE_DIRAUTH_DIRAUTH_OPTIONS_ST_H
#define TOR_FEATURE_DIRAUTH_DIRAUTH_OPTIONS_ST_H

#include "lib/conf/confdecl.h"
#include "feature/nodelist/routerset.h"

#define CONF_CONTEXT STRUCT
#include "feature/dirauth/dirauth_options.inc"
#undef CONF_CONTEXT

typedef struct dirauth_options_t dirauth_options_t;

#endif /* !defined(TOR_FEATURE_DIRAUTH_DIRAUTH_OPTIONS_ST_H) */
