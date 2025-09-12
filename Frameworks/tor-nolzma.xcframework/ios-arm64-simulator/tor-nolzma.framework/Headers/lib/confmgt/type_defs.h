/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file type_defs.h
 * @brief Header for lib/confmgt/type_defs.c
 **/

#ifndef TOR_LIB_CONFMGT_TYPE_DEFS_H
#define TOR_LIB_CONFMGT_TYPE_DEFS_H

const struct var_type_def_t *lookup_type_def(config_type_t type);

#endif /* !defined(TOR_LIB_CONFMGT_TYPE_DEFS_H) */
