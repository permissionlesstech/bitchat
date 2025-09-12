/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file structvar.h
 * @brief Header for lib/confmgt/structvar.c
 **/

#ifndef TOR_LIB_CONFMGT_STRUCTVAR_H
#define TOR_LIB_CONFMGT_STRUCTVAR_H

struct struct_magic_decl_t;
struct struct_member_t;
struct config_line_t;

#include <stdbool.h>
#include "lib/cc/torint.h"

void struct_set_magic(void *object,
                      const struct struct_magic_decl_t *decl);
void struct_check_magic(const void *object,
                        const struct struct_magic_decl_t *decl);

void *struct_get_mptr(void *object,
                      const struct struct_member_t *member);
const void *struct_get_ptr(const void *object,
                           const struct struct_member_t *member);

void struct_var_free(void *object,
                     const struct struct_member_t *member);
int struct_var_copy(void *dest, const void *src,
                    const struct struct_member_t *member);
bool struct_var_eq(const void *a, const void *b,
                   const struct struct_member_t *member);
bool struct_var_ok(const void *object,
                   const struct struct_member_t *member);
void struct_var_mark_fragile(void *object,
                             const struct struct_member_t *member);

const char *struct_var_get_name(const struct struct_member_t *member);
const char *struct_var_get_typename(const struct struct_member_t *member);
uint32_t struct_var_get_flags(const struct struct_member_t *member);

int struct_var_kvassign(void *object, const struct config_line_t *line,
                        char **errmsg,
                        const struct struct_member_t *member);
struct config_line_t *struct_var_kvencode(
                        const void *object,
                        const struct struct_member_t *member);

#endif /* !defined(TOR_LIB_CONFMGT_STRUCTVAR_H) */
