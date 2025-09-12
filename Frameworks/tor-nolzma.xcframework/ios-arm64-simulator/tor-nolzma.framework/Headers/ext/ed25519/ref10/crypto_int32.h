/* Added for Tor. */

#ifndef CRYPTO_INT32_H
#define CRYPTO_INT32_H

#include "lib/cc/torint.h"
#define crypto_int32 int32_t
#define crypto_uint32 uint32_t

/*
 Stop signed left shifts overflowing
 by using unsigned types for bitwise operations
 */

#ifndef OVERFLOW_SAFE_SIGNED_LSHIFT
#define OVERFLOW_SAFE_SIGNED_LSHIFT(s, lshift, utype, stype) \
  ((stype)((utype)(s) << (utype)(lshift)))
#endif

#define SHL32(s, lshift) \
  OVERFLOW_SAFE_SIGNED_LSHIFT(s, lshift, crypto_uint32, crypto_int32)
#define SHL8(s, lshift) \
  OVERFLOW_SAFE_SIGNED_LSHIFT(s, lshift, unsigned char, signed char)

#endif /* CRYPTO_INT32_H */
