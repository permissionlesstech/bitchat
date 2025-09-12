/* Copyright (c) 2021-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dos_options_st.h
 * @brief Structure dos_options_t to hold options for the DoS subsystem.
 **/

#ifndef TOR_CORE_OR_DOS_OPTIONS_ST_H
#define TOR_CORE_OR_DOS_OPTIONS_ST_H

#include "lib/conf/confdecl.h"

#define CONF_CONTEXT STRUCT
#include "core/or/dos_options.inc"
#undef CONF_CONTEXT

typedef struct dos_options_t dos_options_t;

#endif /* !defined(TOR_CORE_OR_DOS_OPTIONS_ST_H) */
