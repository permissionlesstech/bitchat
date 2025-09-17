/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file confline.h
 *
 * \brief Header for confline.c
 **/

#ifndef TOR_CONFLINE_H
#define TOR_CONFLINE_H

struct smartlist_t;

/** Ordinary configuration line. */
#define CONFIG_LINE_NORMAL 0
/** Appends to previous configuration for the same option, even if we
 * would ordinary replace it. */
#define CONFIG_LINE_APPEND 1
/* Removes all previous configuration for an option. */
#define CONFIG_LINE_CLEAR 2

#define MAX_INCLUDE_RECURSION_LEVEL 31

/** A linked list of lines in a config file, or elsewhere */
typedef struct config_line_t {
  char *key;
  char *value;
  struct config_line_t *next;

  /** What special treatment (if any) does this line require? */
  unsigned int command:2;
  /** If true, subsequent assignments to this linelist should replace
   * it, not extend it.  Set only on the first item in a linelist in an
   * or_options_t. */
  unsigned int fragile:1;
} config_line_t;

void config_line_append(config_line_t **lst,
                        const char *key, const char *val);
void config_line_prepend(config_line_t **lst,
                         const char *key, const char *val);
config_line_t *config_lines_dup(const config_line_t *inp);
config_line_t *config_lines_dup_and_filter(const config_line_t *inp,
                                           const char *key);
const config_line_t *config_line_find(const config_line_t *lines,
                                      const char *key);
const config_line_t *config_line_find_case(const config_line_t *lines,
                                           const char *key);
config_line_t *config_lines_partition(config_line_t *inp, const char *header);
int config_lines_eq(const config_line_t *a, const config_line_t *b);
int config_count_key(const config_line_t *a, const char *key);
void config_free_lines_(config_line_t *front);
#define config_free_lines(front) \
  do {                           \
    config_free_lines_(front);   \
    (front) = NULL;              \
  } while (0)
const char *parse_config_line_from_str_verbose(const char *line,
                                       char **key_out, char **value_out,
                                       const char **err_out);

int config_get_lines(const char *string, struct config_line_t **result,
                     int extended);

typedef int (*include_handler_fn)(const char *, int, int,
                                  struct config_line_t **,
                                  struct config_line_t **,
                                  struct smartlist_t *);

int config_get_lines_aux(const char *string, struct config_line_t **result,
                         int extended,
                         int allow_include, int *has_include,
                         struct smartlist_t *opened_lst, int recursion_level,
                         config_line_t **last,
                         include_handler_fn handle_include);

#endif /* !defined(TOR_CONFLINE_H) */
