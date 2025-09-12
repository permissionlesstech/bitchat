/*
	a custom randombytes must implement:

	void ED25519_FN(ed25519_randombytes_unsafe) (void *p, size_t len);

	ed25519_randombytes_unsafe is used by the batch verification function
	to create random scalars
*/

/* Tor: Instead of calling OpenSSL's CSPRNG directly, call the wrapper. */
#include "lib/crypt_ops/crypto_rand.h"

static void
ED25519_FN(ed25519_randombytes_unsafe) (void *p, size_t len)
{
  crypto_rand_unmocked(p, len);
}
