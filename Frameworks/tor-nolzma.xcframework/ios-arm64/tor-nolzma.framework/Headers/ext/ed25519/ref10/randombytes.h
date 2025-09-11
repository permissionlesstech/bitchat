/* Added for Tor. */
#include "lib/crypt_ops/crypto_rand.h"
#define randombytes(b, n) \
  (crypto_strongest_rand((b), (n)), 0)
