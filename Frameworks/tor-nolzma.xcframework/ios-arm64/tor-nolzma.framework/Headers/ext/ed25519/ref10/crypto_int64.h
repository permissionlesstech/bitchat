/* Added for Tor. */

#ifndef CRYPTO_INT64_H
#define CRYPTO_INT64_H

#include "lib/cc/torint.h"
#define crypto_int64 int64_t
#define crypto_uint64 uint64_t

/*
 Stop signed left shifts overflowing
 by using unsigned types for bitwise operations
 */

#ifndef OVERFLOW_SAFE_SIGNED_LSHIFT
#define OVERFLOW_SAFE_SIGNED_LSHIFT(s, lshift, utype, stype) \
  ((stype)((utype)(s) << (utype)(lshift)))
#endif

#define SHL64(s, lshift) \
  OVERFLOW_SAFE_SIGNED_LSHIFT(s, lshift, crypto_uint64, crypto_int64)

#endif /* CRYPTO_INT64_H */
