/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file mainloop_state_st.h
 * @brief Declare a state structure for mainloop-relevant fields
 **/

#ifndef TOR_CORE_MAINLOOP_MAINLOOP_STATE_ST_H
#define TOR_CORE_MAINLOOP_MAINLOOP_STATE_ST_H

#include "lib/conf/confdecl.h"

#define CONF_CONTEXT STRUCT
#include "core/mainloop/mainloop_state.inc"
#undef CONF_CONTEXT

typedef struct mainloop_state_t mainloop_state_t;

#endif /* !defined(TOR_CORE_MAINLOOP_MAINLOOP_STATE_ST_H) */
