/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file conftesting.h
 * @brief Macro and type declarations for testing
 **/

#ifndef TOR_LIB_CONF_CONFTESTING_H
#define TOR_LIB_CONF_CONFTESTING_H

#include "lib/cc/torint.h"

#ifndef COCCI
#ifdef TOR_UNIT_TESTS
#define USE_CONF_TESTING
/**
 * Union used when building in test mode typechecking the members of a type
 * used with confmgt.c.  See CONF_CHECK_VAR_TYPE for a description of how
 * it is used. */
typedef union {
  char **STRING;
  char **FILENAME;
  int *POSINT; /* yes, this is really an int, and not an unsigned int.  For
                * historical reasons, many configuration values are restricted
                * to the range [0,INT_MAX], and stored in signed ints.
                */
  uint64_t *UINT64;
  int *INT;
  int *INTERVAL;
  int *MSEC_INTERVAL;
  uint64_t *MEMUNIT;
  double *DOUBLE;
  int *BOOL;
  int *AUTOBOOL;
  time_t *ISOTIME;
  struct smartlist_t **CSV;
  int *CSV_INTERVAL;
  struct config_line_t **LINELIST;
  struct config_line_t **LINELIST_S;
  struct config_line_t **LINELIST_V;
  // XXXX this doesn't belong at this level of abstraction.
  struct routerset_t **ROUTERSET;
} confparse_dummy_values_t;

/* Macros to define extra members inside config_var_t fields, and at the
 * end of a list of them.
 */
/* This is a somewhat magic type-checking macro for users of confmgt.c.
 * It initializes a union member "confparse_dummy_values_t.conftype" with
 * the address of a static member "tp_dummy.member".   This
 * will give a compiler warning unless the member field is of the correct
 * type.
 *
 * (This warning is mandatory, because a type mismatch here violates the type
 * compatibility constraint for simple assignment, and requires a diagnostic,
 * according to the C spec.)
 *
 * For example, suppose you say:
 *     "CONF_CHECK_VAR_TYPE(or_options_t, STRING, Address)".
 * Then this macro will evaluate to:
 *     { .STRING = &or_options_t_dummy.Address }
 * And since confparse_dummy_values_t.STRING has type "char **", that
 * expression will create a warning unless or_options_t.Address also
 * has type "char *".
 */
#define CONF_CHECK_VAR_TYPE(tp, conftype, member)       \
  { . conftype = &tp ## _dummy . member }
#define CONF_TEST_MEMBERS(tp, conftype, member) \
  , .var_ptr_dummy=CONF_CHECK_VAR_TYPE(tp, conftype, member)
#define DUMMY_CONF_TEST_MEMBERS , .var_ptr_dummy={ .INT=NULL }
#define DUMMY_TYPECHECK_INSTANCE(tp)            \
  static tp tp ## _dummy
#endif /* defined(TOR_UNIT_TESTS) */
#endif /* !defined(COCCI) */

#ifndef USE_CONF_TESTING
#define CONF_TEST_MEMBERS(tp, conftype, member)
/* Repeatedly declarable incomplete struct to absorb redundant semicolons */
#define DUMMY_TYPECHECK_INSTANCE(tp)            \
  struct tor_semicolon_eater
#define DUMMY_CONF_TEST_MEMBERS

#endif /* !defined(USE_CONF_TESTING) */

#endif /* !defined(TOR_LIB_CONF_CONFTESTING_H) */
