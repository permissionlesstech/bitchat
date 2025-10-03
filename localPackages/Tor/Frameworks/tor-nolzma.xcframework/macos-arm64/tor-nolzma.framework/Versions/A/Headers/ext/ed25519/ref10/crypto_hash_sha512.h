/* Added for Tor. */
#include "lib/crypt_ops/crypto_digest.h"

/* Set 'out' to the 512-bit SHA512 hash of the 'len'-byte string in 'inp' */
#define crypto_hash_sha512(out, inp, len) \
  crypto_digest512((char *)(out), (const char *)(inp), (len), DIGEST_SHA512)

/* Set 'out' to the 512-bit SHA512 hash of the 'len1'-byte string in 'inp1',
 * concatenated with the 'len2'-byte string in 'inp2'. */
#define crypto_hash_sha512_2(out, inp1, len1, inp2, len2)               \
  do {                                                                  \
    crypto_digest_t *sha_ctx_;						\
    sha_ctx_ = crypto_digest512_new(DIGEST_SHA512);			\
    crypto_digest_add_bytes(sha_ctx_, (const char *)(inp1), (len1));	\
    crypto_digest_add_bytes(sha_ctx_, (const char *)(inp2), (len2));	\
    crypto_digest_get_digest(sha_ctx_, (char *)out, DIGEST512_LEN);	\
    crypto_digest_free(sha_ctx_);					\
  } while (0)

/* Set 'out' to the 512-bit SHA512 hash of the 'len1'-byte string in 'inp1',
 * concatenated with the 'len2'-byte string in 'inp2', concatenated with
 * the 'len3'-byte string in 'len3'. */
#define crypto_hash_sha512_3(out, inp1, len1, inp2, len2, inp3, len3)   \
  do {                                                                  \
    crypto_digest_t *sha_ctx_;						\
    sha_ctx_ = crypto_digest512_new(DIGEST_SHA512);			\
    crypto_digest_add_bytes(sha_ctx_, (const char *)(inp1), (len1));	\
    crypto_digest_add_bytes(sha_ctx_, (const char *)(inp2), (len2));	\
    crypto_digest_add_bytes(sha_ctx_, (const char *)(inp3), (len3));	\
    crypto_digest_get_digest(sha_ctx_, (char *)out, DIGEST512_LEN);	\
    crypto_digest_free(sha_ctx_);					\
 } while(0)
