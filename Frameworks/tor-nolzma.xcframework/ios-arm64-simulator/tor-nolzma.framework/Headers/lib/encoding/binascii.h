/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file binascii.h
 *
 * \brief Header for binascii.c
 **/

#ifndef TOR_BINASCII_H
#define TOR_BINASCII_H

#include "orconfig.h"
#include <stddef.h>
#include "lib/testsupport/testsupport.h"
#include "lib/cc/torint.h"

const char *hex_str(const char *from, size_t fromlen);

/** @{ */
/** These macros don't check for overflow.  Use them only for constant inputs
 * (like array declarations).  The *_LEN macros are the raw encoding lengths
 * (without terminating NUL), while the *_BUFSIZE macros count the terminating
 * NUL. */
#define BASE64_LEN(n) (CEIL_DIV((n), 3) * 4)
#define BASE32_LEN(n) (CEIL_DIV((n), 5) * 8)
#define BASE16_LEN(n) ((n) * 2)

#define BASE64_BUFSIZE(n) (BASE64_LEN(n) + 1)
#define BASE32_BUFSIZE(n) (BASE32_LEN(n) + 1)
#define BASE16_BUFSIZE(n) (BASE16_LEN(n) + 1)

#define BASE64_NOPAD_LEN(n) (CEIL_DIV((n) * 4, 3))
#define BASE32_NOPAD_LEN(n) (CEIL_DIV((n) * 8, 5))

#define BASE64_NOPAD_BUFSIZE(n) (BASE64_NOPAD_LEN(n) + 1)
#define BASE32_NOPAD_BUFSIZE(n) (BASE32_NOPAD_LEN(n) + 1)
/** @} */

#define BASE64_ENCODE_MULTILINE 1
size_t base64_encode_size(size_t srclen, int flags);
size_t base64_decode_maxsize(size_t srclen);
int base64_encode(char *dest, size_t destlen, const char *src, size_t srclen,
                  int flags);
int base64_decode(char *dest, size_t destlen, const char *src, size_t srclen);
int base64_encode_nopad(char *dest, size_t destlen,
                        const uint8_t *src, size_t srclen);

/** Characters that can appear (case-insensitively) in a base32 encoding. */
#define BASE32_CHARS "abcdefghijklmnopqrstuvwxyz234567"
void base32_encode(char *dest, size_t destlen, const char *src, size_t srclen);
int base32_decode(char *dest, size_t destlen, const char *src, size_t srclen);
size_t base32_encoded_size(size_t srclen);

void base16_encode(char *dest, size_t destlen, const char *src, size_t srclen);
int base16_decode(char *dest, size_t destlen, const char *src, size_t srclen);

#endif /* !defined(TOR_BINASCII_H) */
