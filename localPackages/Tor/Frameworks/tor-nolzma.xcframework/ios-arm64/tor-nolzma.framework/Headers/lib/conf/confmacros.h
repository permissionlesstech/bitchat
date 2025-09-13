/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file confmacros.h
 * @brief Macro definitions for declaring configuration variables
 **/

#ifndef TOR_LIB_CONF_CONFMACROS_H
#define TOR_LIB_CONF_CONFMACROS_H

#include "orconfig.h"
#include "lib/conf/conftesting.h"

#ifndef COCCI
/**
 * Used to indicate the end of an array of configuration variables.
 **/
#define END_OF_CONFIG_VARS                                      \
  { .member = { .name = NULL } DUMMY_CONF_TEST_MEMBERS }
#endif /* !defined(COCCI) */

/**
 * Declare a config_var_t as a member named <b>membername</b> of the structure
 * <b>structtype</b>, whose user-visible name is <b>varname</b>, whose
 * type corresponds to the config_type_t member CONFIG_TYPE_<b>vartype</b>,
 * and whose initial value is <b>intval</b>.
 *
 * Most modules that use this macro should wrap it in a local macro that
 * sets structtype to the local configuration type.
 **/
#define CONFIG_VAR_ETYPE(structtype, varname, vartype, membername,      \
                         varflags, initval)                             \
  { .member =                                                           \
    { .name = varname,                                                  \
      .type = CONFIG_TYPE_ ## vartype,                                  \
      .offset = offsetof(structtype, membername),                       \
    },                                                                  \
    .flags = varflags,                                                  \
    .initvalue = initval                                                \
    CONF_TEST_MEMBERS(structtype, vartype, membername)                  \
  }

/**
 * As CONFIG_VAR_ETYPE, but declares a value using an extension type whose
 * type definition is <b>vartype</b>_type_defn.
 **/
#define CONFIG_VAR_DEFN(structtype, varname, vartype, membername,       \
                        varflags, initval)                              \
  { .member =                                                           \
    { .name = varname,                                                \
      .type = CONFIG_TYPE_EXTENDED,                                     \
      .type_def = &vartype ## _type_defn,                               \
      .offset = offsetof(structtype, membername),                       \
    },                                                                  \
    .flags = varflags,                                                  \
    .initvalue = initval                                                \
    CONF_TEST_MEMBERS(structtype, vartype, membername)                  \
  }

/**
 * Declare an obsolete configuration variable with a given name.
 **/
#define CONFIG_VAR_OBSOLETE(varname)            \
  { .member = { .name = varname, .type = CONFIG_TYPE_OBSOLETE },        \
    .flags = CFLG_GROUP_OBSOLETE                                        \
  }

#endif /* !defined(TOR_LIB_CONF_CONFMACROS_H) */
