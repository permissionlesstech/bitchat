/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_ctype.h
 * \brief Locale-independent character-type inspection (header)
 **/

#ifndef TOR_COMPAT_CTYPE_H
#define TOR_COMPAT_CTYPE_H

#include "orconfig.h"
#include "lib/cc/torint.h"

/* Much of the time when we're checking ctypes, we're doing spec compliance,
 * which all assumes we're doing ASCII. */
#define DECLARE_CTYPE_FN(name)                                          \
  static int TOR_##name(char c);                                        \
  extern const uint32_t TOR_##name##_TABLE[];                           \
  static inline int TOR_##name(char c) {                                \
    uint8_t u = c;                                                      \
    return !!(TOR_##name##_TABLE[(u >> 5) & 7] & (1u << (u & 31)));     \
  }
DECLARE_CTYPE_FN(ISALPHA)
DECLARE_CTYPE_FN(ISALNUM)
DECLARE_CTYPE_FN(ISSPACE)
DECLARE_CTYPE_FN(ISDIGIT)
DECLARE_CTYPE_FN(ISXDIGIT)
DECLARE_CTYPE_FN(ISPRINT)
DECLARE_CTYPE_FN(ISLOWER)
DECLARE_CTYPE_FN(ISUPPER)
extern const uint8_t TOR_TOUPPER_TABLE[];
extern const uint8_t TOR_TOLOWER_TABLE[];
#define TOR_TOLOWER(c) (TOR_TOLOWER_TABLE[(uint8_t)c])
#define TOR_TOUPPER(c) (TOR_TOUPPER_TABLE[(uint8_t)c])

static inline int hex_decode_digit(char c);

/** Helper: given a hex digit, return its value, or -1 if it isn't hex. */
static inline int
hex_decode_digit(char c)
{
  switch (c) {
    case '0': return 0;
    case '1': return 1;
    case '2': return 2;
    case '3': return 3;
    case '4': return 4;
    case '5': return 5;
    case '6': return 6;
    case '7': return 7;
    case '8': return 8;
    case '9': return 9;
    case 'A': case 'a': return 10;
    case 'B': case 'b': return 11;
    case 'C': case 'c': return 12;
    case 'D': case 'd': return 13;
    case 'E': case 'e': return 14;
    case 'F': case 'f': return 15;
    default:
      return -1;
  }
}

#endif /* !defined(TOR_COMPAT_CTYPE_H) */
