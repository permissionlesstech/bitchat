/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file confdecl.h
 * @brief Macros for generating a configuration struct from a list
 *   of its individual fields.
 *
 * This header defines three important macros: BEGIN_CONF_STRUCT(),
 * END_CONF_STRUCT(), and CONF_VAR().  They're meant to be used together to
 * define a configuration structure and the means for encoding and decoding
 * it.
 *
 * To use them, make a new header with a name like `MOD_options.inc`.  Start
 * it with a BEGIN_CONF_STRUCT(), then define your variables with CONF_VAR(),
 * then end the header with END_CONF_STRUCT(), as in:
 *
 *     BEGIN_CONF_STRUCT(module_options_t)
 *     CONF_VAR(ModuleIsActive, BOOLEAN, 0, "1")
 *     END_CONF_STRUCT(module_options_t)
 *
 * Once you've done that, you can use that header to define a configuration
 * structure by saying:
 *
 *     typedef struct module_options_t module_options_t;
 *     #define CONF_CONTEXT STRUCT
 *     #include "MOD_options.inc"
 *     #undef CONF_CONTEXT
 *
 * And you can define your field definition table by saying:
 *
 *     #define CONF_CONTEXT TABLE
 *     #include "MOD_options.inc"
 *     #undef CONF_CONTEXT
 *
 * The two above snippets will define a structure called `module_options_t`
 * with appropriate members, and a table of config_var_t objects called
 * `module_options_t_vars[]`.
 *
 * For lower-level modules, you can say <tt>\#define CONF_TABLE LL_TABLE</tt>,
 * and get a table definition suitable for use in modules that are at a lower
 * level than lib/confmgt.  Note that the types for these tables cannot
 * include any extended types.
 **/

#ifndef TOR_LIB_CONF_CONFDECL_H
#define TOR_LIB_CONF_CONFDECL_H

#undef CONF_CONTEXT
#include "lib/cc/tokpaste.h"
#include "lib/cc/torint.h"

/**
 * Begin the definition of a configuration object called `name`.
 **/
#define BEGIN_CONF_STRUCT(name) \
  PASTE(BEGIN_CONF_STRUCT__, CONF_CONTEXT)(name)
/**
 * End the definition of a configuration object called `name`.
 **/
#define END_CONF_STRUCT(name) \
  PASTE(END_CONF_STRUCT__, CONF_CONTEXT)(name)
/**
 * Declare a single configuration field with name `varname`, type `vartype`,
 * flags `varflags`, and initial value `initval`.
 **/
#define CONF_VAR(varname, vartype, varflags, initval)   \
  PASTE(CONF_VAR__, CONF_CONTEXT)(varname, vartype, varflags, initval)

#ifndef COCCI
/**
 * @defgroup STRUCT_MACROS Internal macros: struct definitions.
 * Implementation helpers: the regular confdecl macros expand to these
 * when CONF_CONTEXT is defined to STRUCT.  Don't use them directly.
 * @{*/
#define BEGIN_CONF_STRUCT__STRUCT(name)         \
  struct name {                                 \
  uint32_t magic;
#define END_CONF_STRUCT__STRUCT(name)           \
  };
#define CONF_VAR__STRUCT(varname, vartype, varflags, initval)   \
  config_decl_ ## vartype varname;
/** @} */

/**
 * @defgroup TABLE_MACROS Internal macros: table definitions.
 * Implementation helpers: the regular confdecl macros expand to these
 * when CONF_CONTEXT is defined to TABLE.  Don't use them directly.
 * @{*/
#define BEGIN_CONF_STRUCT__TABLE(structname)                            \
  /* We use this typedef so we can refer to the config type */          \
  /* without having its name as a macro argument to CONF_VAR. */        \
  typedef struct structname config_var_reference__obj;  \
  static const config_var_t structname##_vars[] = {
#define END_CONF_STRUCT__TABLE(structname)      \
  { .member = { .name = NULL } }                \
    };
#define CONF_VAR__TABLE(varname, vartype, varflags, initval)    \
  {                                                             \
   .member =                                                    \
   { .name = #varname,                                          \
     .type = CONFIG_TYPE_EXTENDED,                              \
     .type_def = &vartype ## _type_defn,                        \
     .offset=offsetof(config_var_reference__obj, varname),      \
   },                                                           \
   .flags = varflags,                                           \
   .initvalue = initval                                         \
  },
/**@}*/

/**
 * @defgroup LL_TABLE_MACROS Internal macros: low-level table definitions.
 * Implementation helpers: the regular confdecl macros expand to these
 * when CONF_CONTEXT is defined to LL_TABLE.  Don't use them directly.
 * @{*/
#define BEGIN_CONF_STRUCT__LL_TABLE(structname)                         \
  /* We use this typedef so we can refer to the config type */          \
  /* without having its name as a macro argument to CONF_VAR. */        \
  typedef struct structname config_var_reference__obj;  \
  static const config_var_t structname##_vars[] = {
#define END_CONF_STRUCT__LL_TABLE(structname)   \
  { .member = { .name = NULL } }                \
    };
#define CONF_VAR__LL_TABLE(varname, vartype, varflags, initval) \
  {                                                             \
   .member =                                                    \
   { .name = #varname,                                          \
     .type = CONFIG_TYPE_ ## vartype,                           \
     .offset=offsetof(config_var_reference__obj, varname),      \
   },                                                           \
   .flags = varflags,                                           \
   .initvalue = initval                                         \
  },
/**@}*/

/** @defgroup STUB_TABLE_MACROS Internal macros: stub table declarations,
 * for use when a module is disabled.
 * Implementation helpers: the regular confdecl macros expand to these
 * when CONF_CONTEXT is defined to LL_TABLE.  Don't use them directly.
 * @{ */
#define BEGIN_CONF_STRUCT__STUB_TABLE(structname)                       \
  static const config_var_t structname##_vars[] = {
#define END_CONF_STRUCT__STUB_TABLE(structname)   \
  { .member = { .name = NULL } }                \
    };
#define CONF_VAR__STUB_TABLE(varname, vartype, varflags, initval)       \
  {                                                             \
   .member =                                                    \
   { .name = #varname,                                          \
     .type = CONFIG_TYPE_IGNORE,                                \
     .offset = -1,                                              \
   },                                                           \
   .flags = CFLG_GROUP_DISABLED,                                \
  },
/**@}*/

#endif /* !defined(COCCI) */

/** Type aliases for the "commonly used" configuration types.
 *
 * Defining them in this way allows our CONF_VAR__STRUCT() macro to declare
 * structure members corresponding to the configuration types.  For example,
 * when the macro sees us declare a configuration option "foo" of type STRING,
 * it can emit `config_decl_STRING foo;`, which is an alias for `char *foo`.
 */
/**@{*/
typedef char *config_decl_STRING;
typedef char *config_decl_FILENAME;
/* Yes, "POSINT" is really an int, and not an unsigned int.  For
 * historical reasons, many configuration values are restricted
 * to the range [0,INT_MAX], and stored in signed ints.
 */
typedef int config_decl_POSINT;
typedef uint64_t config_decl_UINT64;
typedef int config_decl_INT;
typedef int config_decl_INTERVAL;
typedef int config_decl_MSEC_INTERVAL;
typedef uint64_t config_decl_MEMUNIT;
typedef double config_decl_DOUBLE;
typedef int config_decl_BOOL;
typedef int config_decl_AUTOBOOL;
typedef time_t config_decl_ISOTIME;
typedef struct smartlist_t config_decl_CSV;
typedef int config_decl_CSV_INTERVAL;
typedef struct config_line_t *config_decl_LINELIST;
typedef struct config_line_t *config_decl_LINELIST_V;
typedef struct nonexistent_struct *config_decl_LINELIST_S;
/**@}*/

struct var_type_def_t;

/* Forward declarations for configuration type definitions. These are used by
 * the CONF_VAR__TABLE macro to set the definition of each variable type
 * correctly.
 */
/**@{*/
extern const struct var_type_def_t STRING_type_defn;
extern const struct var_type_def_t FILENAME_type_defn;
extern const struct var_type_def_t POSINT_type_defn;
extern const struct var_type_def_t UINT64_type_defn;
extern const struct var_type_def_t INT_type_defn;
extern const struct var_type_def_t INTERVAL_type_defn;
extern const struct var_type_def_t MSEC_INTERVAL_type_defn;
extern const struct var_type_def_t MEMUNIT_type_defn;
extern const struct var_type_def_t DOUBLE_type_defn;
extern const struct var_type_def_t BOOL_type_defn;
extern const struct var_type_def_t AUTOBOOL_type_defn;
extern const struct var_type_def_t ISOTIME_type_defn;
extern const struct var_type_def_t CSV_type_defn;
extern const struct var_type_def_t CSV_INTERVAL_type_defn;
extern const struct var_type_def_t LINELIST_type_defn;
extern const struct var_type_def_t LINELIST_V_type_defn;
extern const struct var_type_def_t LINELIST_S_type_defn;
extern const struct var_type_def_t IGNORE_type_defn;
extern const struct var_type_def_t OBSOLETE_type_defn;
/**@}*/

#endif /* !defined(TOR_LIB_CONF_CONFDECL_H) */
