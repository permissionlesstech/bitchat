/*
	a custom hash must have a 512bit digest and implement:

	struct ed25519_hash_context;

	void ed25519_hash_init(ed25519_hash_context *ctx);
	void ed25519_hash_update(ed25519_hash_context *ctx, const uint8_t *in, size_t inlen);
	void ed25519_hash_final(ed25519_hash_context *ctx, uint8_t *hash);
	void ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen);
*/

#include "lib/crypt_ops/crypto_digest.h"

typedef struct ed25519_hash_context {
  crypto_digest_t *ctx;
} ed25519_hash_context;


static void
ed25519_hash_init(ed25519_hash_context *ctx)
{
  ctx->ctx = crypto_digest512_new(DIGEST_SHA512);
}
static void
ed25519_hash_update(ed25519_hash_context *ctx, const uint8_t *in, size_t inlen)
{
  crypto_digest_add_bytes(ctx->ctx, (const char *)in, inlen);
}
static void
ed25519_hash_final(ed25519_hash_context *ctx, uint8_t *hash)
{
  crypto_digest_get_digest(ctx->ctx, (char *)hash, DIGEST512_LEN);
  crypto_digest_free(ctx->ctx);
  ctx->ctx = NULL;
}
static void
ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen)
{
  crypto_digest512((char *)hash, (const char *)in, inlen,
		   DIGEST_SHA512);
}

