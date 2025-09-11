/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file conftypes.h
 * @brief Types used to specify configurable options.
 *
 * This header defines the types that different modules will use in order to
 * declare their configuration and state variables, and tell the configuration
 * management code about those variables.  From the individual module's point
 * of view, its configuration and state are simply data structures.
 *
 * For defining new variable types, see var_type_def_st.h.
 *
 * For the code that manipulates variables defined via this module, see
 * lib/confmgt/, especially typedvar.h and (later) structvar.h.  The
 * configuration manager is responsible for encoding, decoding, and
 * maintaining the configuration structures used by the various modules.
 *
 * STATUS NOTE: This is a work in process refactoring.  It is not yet possible
 *   for modules to define their own variables, and much of the configuration
 *   management code is still in src/app/config/.
 **/

#ifndef TOR_SRC_LIB_CONF_CONFTYPES_H
#define TOR_SRC_LIB_CONF_CONFTYPES_H

#include "lib/cc/torint.h"
#ifdef TOR_UNIT_TESTS
#include "lib/conf/conftesting.h"
#endif

#include <stddef.h>

/** Enumeration of types which option values can take */
typedef enum config_type_t {
  CONFIG_TYPE_STRING = 0,   /**< An arbitrary string. */
  CONFIG_TYPE_FILENAME,     /**< A filename: some prefixes get expanded. */
  CONFIG_TYPE_POSINT,       /**< A non-negative integer less than MAX_INT */
  CONFIG_TYPE_INT,          /**< Any integer. */
  CONFIG_TYPE_UINT64,       /**< A value in range 0..UINT64_MAX */
  CONFIG_TYPE_INTERVAL,     /**< A number of seconds, with optional units*/
  CONFIG_TYPE_MSEC_INTERVAL,/**< A number of milliseconds, with optional
                              * units */
  CONFIG_TYPE_MEMUNIT,      /**< A number of bytes, with optional units*/
  CONFIG_TYPE_DOUBLE,       /**< A floating-point value */
  CONFIG_TYPE_BOOL,         /**< A boolean value, expressed as 0 or 1. */
  CONFIG_TYPE_AUTOBOOL,     /**< A boolean+auto value, expressed 0 for false,
                             * 1 for true, and -1 for auto  */
  CONFIG_TYPE_ISOTIME,      /**< An ISO-formatted time relative to UTC. */
  CONFIG_TYPE_CSV,          /**< A list of strings, separated by commas and
                              * optional whitespace. */
  CONFIG_TYPE_CSV_INTERVAL, /**< A list of strings, separated by commas and
                              * optional whitespace, representing intervals in
                              * seconds, with optional units.  We allow
                              * multiple values here for legacy reasons, but
                              * ignore every value after the first. */
  CONFIG_TYPE_LINELIST,     /**< Uninterpreted config lines */
  CONFIG_TYPE_LINELIST_S,   /**< Uninterpreted, context-sensitive config lines,
                             * mixed with other keywords. */
  CONFIG_TYPE_LINELIST_V,   /**< Catch-all "virtual" option to summarize
                             * context-sensitive config lines when fetching.
                             */
  /** Ignored (obsolete) option. Uses no storage.
   *
   * Reported as "obsolete" when its type is queried.
   */
  CONFIG_TYPE_OBSOLETE,
  /** Ignored option. Uses no storage.
   *
   * Reported as "ignored" when its type is queried. For use with options used
   * by disabled modules.
   **/
  CONFIG_TYPE_IGNORE,

  /**
   * Extended type: definition appears in the <b>type_def</b> pointer
   * of the corresponding struct_member_t.
   *
   * For some types, we cannot define them as particular values of this
   * enumeration, since those types are abstractions defined at a higher level
   * than this module.  (For example, parsing a routerset_t is higher-level
   * than this module.)  To handle this, we use CONFIG_TYPE_EXTENDED for those
   * types, and give a definition for them in the struct_member_t.type_def.
   **/
  CONFIG_TYPE_EXTENDED,
} config_type_t;

/* Forward delcaration for var_type_def_t, for extended types. */
struct var_type_def_t;

/** Structure to specify a named, typed member within a structure. */
typedef struct struct_member_t {
  /** Name of the field. */
  const char *name;
  /**
   * Type of the field, according to the config_type_t enumeration.
   *
   * For any type not otherwise listed in config_type_t, this field's value
   * should be CONFIG_TYPE_EXTENDED.  When it is, the <b>type_def</b> pointer
   * must be set.
   **/
  /*
   * NOTE: In future refactoring, we might remove this field entirely, along
   * with its corresponding enumeration.  In that case, we will require that
   * type_def be set in all cases. If we do, we will also need a new mechanism
   * to enforce consistency between configuration variable types and their
   * corresponding structures, since our current design in
   * lib/conf/conftesting.h won't work any more.
   */
  config_type_t type;
  /**
   * Pointer to a type definition for the type of this field. Overrides
   * <b>type</b> if it is not NULL.  Must be set when <b>type</b> is
   * CONFIG_TYPE_EXTENDED.
   **/
  const struct var_type_def_t *type_def;
  /**
   * Offset of this field within the structure.  Compute this with
   * offsetof(structure, fieldname).
   **/
  ptrdiff_t offset;
} struct_member_t;

/**
 * Structure to describe the location and preferred value of a "magic number"
 * field within a structure.
 *
 * These 'magic numbers' are 32-bit values used to tag objects to make sure
 * that they have the correct type.
 *
 * If all fields in this structure are zero or 0, the magic-number check is
 * not performed.
 */
typedef struct struct_magic_decl_t {
  /** The name of the structure */
  const char *typename;
  /** A value used to recognize instances of this structure. */
  uint32_t magic_val;
  /** The location within the structure at which we expect to find
   * <b>magic_val</b>. */
  ptrdiff_t magic_offset;
} struct_magic_decl_t;

/**
 * Flag to indicate that an option or type is "undumpable". An
 * undumpable option is never saved to disk.
 *
 * For historical reasons its name is usually is prefixed with __.
 **/
#define CFLG_NODUMP    (1u<<0)
/**
 * Flag to indicate that an option or type is "unlisted".
 *
 * We don't tell the controller about unlisted options when it asks for a
 * list of them.
 **/
#define CFLG_NOLIST (1u<<1)
/**
 * Flag to indicate that an option or type is "unsettable".
 *
 * An unsettable option can never be set directly by name.
 **/
#define CFLG_NOSET (1u<<2)
/**
 * Flag to indicate that an option or type does not need to be copied when
 * copying the structure that contains it.
 *
 * (Usually, if an option does not need to be copied, then either it contains
 * no data, or the data that it does contain is completely contained within
 * another option.)
 **/
#define CFLG_NOCOPY (1u<<3)
/**
 * Flag to indicate that an option or type does not need to be compared
 * when telling the controller about the differences between two
 * configurations.
 *
 * (Usually, if an option does not need to be compared, then either it
 * contains no data, or the data that it does contain is completely contained
 * within another option.)
 **/
#define CFLG_NOCMP (1u<<4)
/**
 * Flag to indicate that an option or type should not be replaced when setting
 * it.
 *
 * For most options, setting them replaces their old value.  For some options,
 * however, setting them appends to their old value.
 */
#define CFLG_NOREPLACE    (1u<<5)
/**
 * Flag to indicate that an option or type cannot be changed while Tor is
 * running.
 **/
#define CFLG_IMMUTABLE (1u<<6)
/**
 * Flag to indicate that we should warn that an option or type is obsolete
 * whenever the user tries to use it.
 **/
#define CFLG_WARN_OBSOLETE (1u<<7)
/**
 * Flag to indicate that we should warn that an option applies only to
 * a disabled module, whenever the user tries to use it.
 **/
#define CFLG_WARN_DISABLED (1u<<8)

/**
 * A group of flags that should be set on all obsolete options and types.
 **/
#define CFLG_GROUP_OBSOLETE \
  (CFLG_NOCOPY|CFLG_NOCMP|CFLG_NODUMP|CFLG_NOSET|CFLG_NOLIST|\
   CFLG_WARN_OBSOLETE)

/**
 * A group of fflags that should be set on all disabled options.
 **/
#define CFLG_GROUP_DISABLED \
  (CFLG_NOCOPY|CFLG_NOCMP|CFLG_NODUMP|CFLG_NOSET|CFLG_NOLIST|\
   CFLG_WARN_DISABLED)

/** A variable allowed in the configuration file or on the command line. */
typedef struct config_var_t {
  struct_member_t member; /** A struct member corresponding to this
                           * variable. */
  const char *initvalue; /**< String (or null) describing initial value. */
  uint32_t flags; /**< One or more flags describing special handling for this
                   * variable */
#ifdef TOR_UNIT_TESTS
  /** Used for compiler-magic to typecheck the corresponding field in the
   * corresponding struct. Only used in unit test mode, at compile-time. */
  confparse_dummy_values_t var_ptr_dummy;
#endif
} config_var_t;

/**
 * An abbreviation or alias for a configuration option.
 **/
typedef struct config_abbrev_t {
  /** The option name as abbreviated.  Not case-sensitive. */
  const char *abbreviated;
  /** The full name of the option. Not case-sensitive. */
  const char *full;
  /** True if this abbreviation should only be allowed on the command line. */
  int commandline_only;
  /** True if we should warn whenever this abbreviation is used. */
  int warn;
} config_abbrev_t;

/**
 * A note that a configuration option is deprecated, with an explanation why.
 */
typedef struct config_deprecation_t {
  /** The option that is deprecated. */
  const char *name;
  /** A user-facing string explaining why the option is deprecated. */
  const char *why_deprecated;
} config_deprecation_t;

#ifndef COCCI
/**
 * Handy macro for declaring "In the config file or on the command line, you
 * can abbreviate <b>tok</b>s as <b>tok</b>". Used inside an array of
 * config_abbrev_t.
 *
 * For example, to declare "NumCpu" as an abbreviation for "NumCPUs",
 * you can say PLURAL(NumCpu).
 **/
#define PLURAL(tok) { (#tok), (#tok "s"), 0, 0 }
#endif /* !defined(COCCI) */

/**
 * Validation function: verify whether a configuration object is well-formed
 * and consistent.
 *
 * On success, return 0.  On failure, set <b>msg_out</b> to a newly allocated
 * string containing an error message, and return -1. */
typedef int (*validate_fn_t)(const void *value, char **msg_out);
/**
 * Validation function: verify whether a configuration object (`value`) is an
 * allowable value given the previous configuration value (`old_value`).
 *
 * On success, return 0.  On failure, set <b>msg_out</b> to a newly allocated
 * string containing an error message, and return -1. */
typedef int (*check_transition_fn_t)(const void *old_value, const void *value,
                                     char **msg_out);
/**
 * Validation function: normalize members of `value`, and compute derived
 * members.
 *
 * This function is called before any other validation of `value`, and must
 * not assume that validate_fn or check_transition_fn has passed.
 *
 * On success, return 0.  On failure, set <b>msg_out</b> to a newly allocated
 * string containing an error message, and return -1. */
typedef int (*pre_normalize_fn_t)(void *value, char **msg_out);
/**
 * Validation function: normalize members of `value`, and compute derived
 * members.
 *
 * This function is called after validation of `value`, and may
 * assume that validate_fn or check_transition_fn has passed.
 *
 * On success, return 0.  On failure, set <b>msg_out</b> to a newly allocated
 * string containing an error message, and return -1. */
typedef int (*post_normalize_fn_t)(void *value, char **msg_out);

/**
 * Legacy function to validate whether a given configuration is
 * well-formed and consistent.
 *
 * The configuration to validate is passed as <b>newval</b>. The previous
 * configuration, if any, is provided in <b>oldval</b>.
 *
 * This API is deprecated, since it mixes the responsibilities of
 * pre_normalize_fn_t, post_normalize_fn_t, validate_fn_t, and
 * check_transition_fn_t.  No new instances of this function type should
 * be written.
 *
 * On success, return 0.  On failure, set *<b>msg_out</b> to a newly allocated
 * error message, and return -1.
 */
typedef int (*legacy_validate_fn_t)(const void *oldval,
                                    void *newval,
                                    char **msg_out);

struct config_mgr_t;

/**
 * Callback to clear all non-managed fields of a configuration object.
 *
 * <b>obj</b> is the configuration object whose non-managed fields should be
 * cleared.
 *
 * (Regular fields get cleared by config_reset(), but you might have fields
 * in the object that do not correspond to configuration variables.  If those
 * fields need to be cleared or freed, this is where to do it.)
 */
typedef void (*clear_cfg_fn_t)(const struct config_mgr_t *mgr, void *obj);

/** Information on the keys, value types, key-to-struct-member mappings,
 * variable descriptions, validation functions, and abbreviations for a
 * configuration or storage format. */
typedef struct config_format_t {
  size_t size; /**< Size of the struct that everything gets parsed into. */
  struct_magic_decl_t magic; /**< Magic number info for this struct. */
  const config_abbrev_t *abbrevs; /**< List of abbreviations that we expand
                             * when parsing this format. */
  const config_deprecation_t *deprecations; /** List of deprecated options */
  const config_var_t *vars; /**< List of variables we recognize, their default
                             * values, and where we stick them in the
                             * structure. */

  /** Early-stage normalization callback. Invoked by config_validate(). */
  pre_normalize_fn_t pre_normalize_fn;
  /** Configuration validation function. Invoked by config_validate(). */
  validate_fn_t validate_fn;
    /** Legacy validation function. Invoked by config_validate(). */
  legacy_validate_fn_t legacy_validate_fn;
  /** Transition checking function. Invoked by config_validate(). */
  check_transition_fn_t check_transition_fn;
  /** Late-stage normalization callback. Invoked by config_validate(). */
  post_normalize_fn_t post_normalize_fn;

  clear_cfg_fn_t clear_fn; /**< Function to clear the configuration. */
  /** If present, extra denotes a LINELIST variable for unrecognized
   * lines.  Otherwise, unrecognized lines are an error. */
  const struct_member_t *extra;
  /**
   * If true, this format describes a top-level configuration, with
   * a suite containing multiple sub-configuration objects.
   */
  bool has_config_suite;
  /** The position of a config_suite_t pointer within the toplevel object.
   * Ignored unless have_config_suite is true.
   */
  ptrdiff_t config_suite_offset;
} config_format_t;

#endif /* !defined(TOR_SRC_LIB_CONF_CONFTYPES_H) */
