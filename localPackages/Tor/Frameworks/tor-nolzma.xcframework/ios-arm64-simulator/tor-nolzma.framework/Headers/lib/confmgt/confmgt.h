/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file confmgt.h
 *
 * \brief Header for confmgt.c.
 */

#ifndef TOR_CONFMGT_H
#define TOR_CONFMGT_H

#include "lib/conf/conftypes.h"
#include "lib/conf/confmacros.h"
#include "lib/testsupport/testsupport.h"

/**
 * A collection of config_format_t objects to describe several objects
 * that are all configured with the same configuration file.
 *
 * (NOTE: for now, this only handles a single config_format_t.)
 **/
typedef struct config_mgr_t config_mgr_t;

config_mgr_t *config_mgr_new(const config_format_t *toplevel_fmt);
void config_mgr_free_(config_mgr_t *mgr);
int config_mgr_add_format(config_mgr_t *mgr,
                          const config_format_t *fmt);
void config_mgr_freeze(config_mgr_t *mgr);
#define config_mgr_free(mgr) \
  FREE_AND_NULL(config_mgr_t, config_mgr_free_, (mgr))
struct smartlist_t *config_mgr_list_vars(const config_mgr_t *mgr);
struct smartlist_t *config_mgr_list_deprecated_vars(const config_mgr_t *mgr);

/** A collection of managed configuration objects. */
typedef struct config_suite_t config_suite_t;

/**
 * Flag for config_assign: if set, then "resetting" an option changes it to
 * its default value, as specified in the config_var_t.  Otherwise,
 * "resetting" an option changes it to a type-dependent null value --
 * typically 0 or NULL.
 *
 * (An option is "reset" when it is set to an empty value, or as described in
 * CAL_CLEAR_FIRST).
 **/
#define CAL_USE_DEFAULTS      (1u<<0)
/**
 * Flag for config_assign: if set, then we reset every provided config
 * option before we set it.
 *
 * For example, if this flag is not set, then passing a multi-line option to
 * config_assign will cause any previous value to be extended. But if this
 * flag is set, then a multi-line option will replace any previous value.
 **/
#define CAL_CLEAR_FIRST       (1u<<1)
/**
 * Flag for config_assign: if set, we warn about deprecated options.
 **/
#define CAL_WARN_DEPRECATIONS (1u<<2)

void *config_new(const config_mgr_t *fmt);
void config_free_(const config_mgr_t *fmt, void *options);
#define config_free(mgr, options) do {                \
    config_free_((mgr), (options));                   \
    (options) = NULL;                                 \
  } while (0)

struct config_line_t *config_get_assigned_option(const config_mgr_t *mgr,
                                          const void *options, const char *key,
                                          int escape_val);
int config_is_same(const config_mgr_t *fmt,
                   const void *o1, const void *o2,
                   const char *name);
struct config_line_t *config_get_changes(const config_mgr_t *mgr,
                                  const void *options1, const void *options2);
void config_init(const config_mgr_t *mgr, void *options);

/** An enumeration to report which validation step failed. */
typedef enum {
  VSTAT_PRE_NORMALIZE_ERR = -5,
  VSTAT_VALIDATE_ERR = -4,
  VSTAT_LEGACY_ERR = -3,
  VSTAT_TRANSITION_ERR = -2,
  VSTAT_POST_NORMALIZE_ERR = -1,
  VSTAT_OK = 0,
} validation_status_t;

validation_status_t config_validate(const config_mgr_t *mgr,
                                    const void *old_options, void *options,
                                    char **msg_out);
void *config_dup(const config_mgr_t *mgr, const void *old);
char *config_dump(const config_mgr_t *mgr, const void *default_options,
                  const void *options, int minimal,
                  int comment_defaults);
void config_check_toplevel_magic(const config_mgr_t *mgr,
                                 const void *object);
bool config_check_ok(const config_mgr_t *mgr, const void *options,
                     int severity);
int config_assign(const config_mgr_t *mgr, void *options,
                  struct config_line_t *list,
                  unsigned flags, char **msg);
const char *config_find_deprecation(const config_mgr_t *mgr,
                                    const char *key);
const char *config_find_option_name(const config_mgr_t *mgr,
                                    const char *key);
const char *config_expand_abbrev(const config_mgr_t *mgr,
                                 const char *option,
                                 int command_line, int warn_obsolete);
void warn_deprecated_option(const char *what, const char *why);

bool config_var_is_settable(const config_var_t *var);
bool config_var_is_listable(const config_var_t *var);

/* Helper macros to compare an option across two configuration objects */
#define CFG_EQ_BOOL(a,b,opt) ((a)->opt == (b)->opt)
#define CFG_EQ_INT(a,b,opt) ((a)->opt == (b)->opt)
#define CFG_EQ_STRING(a,b,opt) (!strcmp_opt((a)->opt, (b)->opt))
#define CFG_EQ_SMARTLIST(a,b,opt) smartlist_strings_eq((a)->opt, (b)->opt)
#define CFG_EQ_LINELIST(a,b,opt) config_lines_eq((a)->opt, (b)->opt)
#define CFG_EQ_ROUTERSET(a,b,opt) routerset_equal((a)->opt, (b)->opt)

void *config_mgr_get_obj_mutable(const config_mgr_t *mgr,
                                 void *toplevel, int idx);
const void *config_mgr_get_obj(const config_mgr_t *mgr,
                               const void *toplevel, int idx);

#ifdef CONFMGT_PRIVATE
STATIC void config_reset_line(const config_mgr_t *mgr, void *options,
                              const char *key, int use_defaults);
#endif /* defined(CONFMGT_PRIVATE) */

#endif /* !defined(TOR_CONFMGT_H) */
