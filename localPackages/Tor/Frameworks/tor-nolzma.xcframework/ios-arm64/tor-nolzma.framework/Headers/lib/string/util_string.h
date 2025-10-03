/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file util_string.h
 * \brief Header for util_string.c
 **/

#ifndef TOR_UTIL_STRING_H
#define TOR_UTIL_STRING_H

#include "orconfig.h"
#include "lib/cc/compat_compiler.h"

#include <stddef.h>

const void *tor_memmem(const void *haystack, size_t hlen, const void *needle,
                       size_t nlen);
const void *tor_memstr(const void *haystack, size_t hlen,
                       const char *needle);
int fast_mem_is_zero(const char *mem, size_t len);
#define fast_digest_is_zero(d) fast_mem_is_zero((d), DIGEST_LEN)
#define fast_digetst256_is_zero(d) fast_mem_is_zero((d), DIGEST256_LEN)

int tor_digest_is_zero(const char *digest);
int tor_digest256_is_zero(const char *digest);

/** Allowable characters in a hexadecimal string. */
#define HEX_CHARACTERS "0123456789ABCDEFabcdef"
void tor_strlower(char *s);
void tor_strupper(char *s);
void tor_strreplacechar(char *s, char find, char replacement);
int tor_strisprint(const char *s);
int tor_strisnonupper(const char *s);
int tor_strisspace(const char *s);
int strcmp_opt(const char *s1, const char *s2);
int strcmpstart(const char *s1, const char *s2);
int strcasecmpstart(const char *s1, const char *s2);
int strcmpend(const char *s1, const char *s2);
int strcasecmpend(const char *s1, const char *s2);
int fast_memcmpstart(const void *mem, size_t memlen, const char *prefix);

void tor_strstrip(char *s, const char *strip);

const char *eat_whitespace(const char *s);
const char *eat_whitespace_eos(const char *s, const char *eos);
const char *eat_whitespace_no_nl(const char *s);
const char *eat_whitespace_eos_no_nl(const char *s, const char *eos);
const char *find_whitespace(const char *s);
const char *find_whitespace_eos(const char *s, const char *eos);
const char *find_str_at_start_of_line(const char *haystack,
                                      const char *needle);

int string_is_C_identifier(const char *string);

int string_is_utf8(const char *str, size_t len);
int string_is_utf8_no_bom(const char *str, size_t len);

#endif /* !defined(TOR_UTIL_STRING_H) */
