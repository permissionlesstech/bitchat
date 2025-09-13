/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file unitparse.h
 * @brief Header for lib/confmgt/unitparse.c
 **/

#ifndef TOR_LIB_CONFMGT_UNITPARSE_H
#define TOR_LIB_CONFMGT_UNITPARSE_H

#include <lib/cc/torint.h>

/** Mapping from a unit name to a multiplier for converting that unit into a
 * base unit.  Used by config_parse_unit. */
typedef struct unit_table_t {
  const char *unit; /**< The name of the unit */
  uint64_t multiplier; /**< How many of the base unit appear in this unit */
} unit_table_t;

extern const unit_table_t memory_units[];
extern const unit_table_t time_units[];
extern const struct unit_table_t time_msec_units[];

uint64_t config_parse_units(const char *val, const unit_table_t *u, int *ok,
                            char **errmsg_out);

uint64_t config_parse_memunit(const char *s, int *ok);
int config_parse_msec_interval(const char *s, int *ok);
int config_parse_interval(const char *s, int *ok);

#endif /* !defined(TOR_LIB_CONFMGT_UNITPARSE_H) */
