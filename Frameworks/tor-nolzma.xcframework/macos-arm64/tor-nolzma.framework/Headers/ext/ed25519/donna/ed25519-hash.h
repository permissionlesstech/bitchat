#if defined(ED25519_REFHASH)

/* reference/slow SHA-512. really, do not use this */

#define HASH_BLOCK_SIZE 128
#define HASH_DIGEST_SIZE 64

typedef struct sha512_state_t {
	uint64_t H[8];
	uint64_t T[2];
	uint32_t leftover;
	uint8_t buffer[HASH_BLOCK_SIZE];
} sha512_state;

typedef sha512_state ed25519_hash_context;

static const uint64_t sha512_constants[80] = {
	0x428a2f98d728ae22ull, 0x7137449123ef65cdull, 0xb5c0fbcfec4d3b2full, 0xe9b5dba58189dbbcull,
	0x3956c25bf348b538ull, 0x59f111f1b605d019ull, 0x923f82a4af194f9bull, 0xab1c5ed5da6d8118ull,
	0xd807aa98a3030242ull, 0x12835b0145706fbeull, 0x243185be4ee4b28cull, 0x550c7dc3d5ffb4e2ull,
	0x72be5d74f27b896full, 0x80deb1fe3b1696b1ull, 0x9bdc06a725c71235ull, 0xc19bf174cf692694ull,
	0xe49b69c19ef14ad2ull, 0xefbe4786384f25e3ull, 0x0fc19dc68b8cd5b5ull, 0x240ca1cc77ac9c65ull,
	0x2de92c6f592b0275ull, 0x4a7484aa6ea6e483ull, 0x5cb0a9dcbd41fbd4ull, 0x76f988da831153b5ull,
	0x983e5152ee66dfabull, 0xa831c66d2db43210ull, 0xb00327c898fb213full, 0xbf597fc7beef0ee4ull,
	0xc6e00bf33da88fc2ull, 0xd5a79147930aa725ull, 0x06ca6351e003826full, 0x142929670a0e6e70ull,
	0x27b70a8546d22ffcull, 0x2e1b21385c26c926ull, 0x4d2c6dfc5ac42aedull, 0x53380d139d95b3dfull,
	0x650a73548baf63deull, 0x766a0abb3c77b2a8ull, 0x81c2c92e47edaee6ull, 0x92722c851482353bull,
	0xa2bfe8a14cf10364ull, 0xa81a664bbc423001ull, 0xc24b8b70d0f89791ull, 0xc76c51a30654be30ull,
	0xd192e819d6ef5218ull, 0xd69906245565a910ull, 0xf40e35855771202aull, 0x106aa07032bbd1b8ull,
	0x19a4c116b8d2d0c8ull, 0x1e376c085141ab53ull, 0x2748774cdf8eeb99ull, 0x34b0bcb5e19b48a8ull,
	0x391c0cb3c5c95a63ull, 0x4ed8aa4ae3418acbull, 0x5b9cca4f7763e373ull, 0x682e6ff3d6b2b8a3ull,
	0x748f82ee5defb2fcull, 0x78a5636f43172f60ull, 0x84c87814a1f0ab72ull, 0x8cc702081a6439ecull,
	0x90befffa23631e28ull, 0xa4506cebde82bde9ull, 0xbef9a3f7b2c67915ull, 0xc67178f2e372532bull,
	0xca273eceea26619cull, 0xd186b8c721c0c207ull, 0xeada7dd6cde0eb1eull, 0xf57d4f7fee6ed178ull,
	0x06f067aa72176fbaull, 0x0a637dc5a2c898a6ull, 0x113f9804bef90daeull, 0x1b710b35131c471bull,
	0x28db77f523047d84ull, 0x32caab7b40c72493ull, 0x3c9ebe0a15c9bebcull, 0x431d67c49c100d4cull,
	0x4cc5d4becb3e42b6ull, 0x597f299cfc657e2aull, 0x5fcb6fab3ad6faecull, 0x6c44198c4a475817ull
};

static uint64_t
sha512_ROTR64(uint64_t x, int k) {
	return (x >> k) | (x << (64 - k));
}

static uint64_t
sha512_LOAD64_BE(const uint8_t *p) {
	return 
		((uint64_t)p[0] << 56) |
		((uint64_t)p[1] << 48) |
		((uint64_t)p[2] << 40) |
		((uint64_t)p[3] << 32) |
		((uint64_t)p[4] << 24) |
		((uint64_t)p[5] << 16) |
		((uint64_t)p[6] <<  8) |
		((uint64_t)p[7]      );
}

static void
sha512_STORE64_BE(uint8_t *p, uint64_t v) {
	p[0] = (uint8_t)(v >> 56);
	p[1] = (uint8_t)(v >> 48);
	p[2] = (uint8_t)(v >> 40);
	p[3] = (uint8_t)(v >> 32);
	p[4] = (uint8_t)(v >> 24);
	p[5] = (uint8_t)(v >> 16);
	p[6] = (uint8_t)(v >>  8);
	p[7] = (uint8_t)(v      );
}

#define Ch(x,y,z)  (z ^ (x & (y ^ z)))
#define Maj(x,y,z) (((x | y) & z) | (x & y))
#define S0(x)      (sha512_ROTR64(x, 28) ^ sha512_ROTR64(x, 34) ^ sha512_ROTR64(x, 39))
#define S1(x)      (sha512_ROTR64(x, 14) ^ sha512_ROTR64(x, 18) ^ sha512_ROTR64(x, 41))
#define G0(x)      (sha512_ROTR64(x,  1) ^ sha512_ROTR64(x,  8) ^ (x >>  7))
#define G1(x)      (sha512_ROTR64(x, 19) ^ sha512_ROTR64(x, 61) ^ (x >>  6))
#define W0(in,i)   (sha512_LOAD64_BE(&in[i * 8]))
#define W1(i)      (G1(w[i - 2]) + w[i - 7] + G0(w[i - 15]) + w[i - 16])
#define STEP(i) \
	t1 = S0(r[0]) + Maj(r[0], r[1], r[2]); \
	t0 = r[7] + S1(r[4]) + Ch(r[4], r[5], r[6]) + sha512_constants[i] + w[i]; \
	r[7] = r[6]; \
	r[6] = r[5]; \
	r[5] = r[4]; \
	r[4] = r[3] + t0; \
	r[3] = r[2]; \
	r[2] = r[1]; \
	r[1] = r[0]; \
	r[0] = t0 + t1;

static void
sha512_blocks(sha512_state *S, const uint8_t *in, size_t blocks) {
	uint64_t r[8], w[80], t0, t1;
	size_t i;

	for (i = 0; i < 8; i++) r[i] = S->H[i];

	while (blocks--) {
		for (i =  0; i < 16; i++) { w[i] = W0(in, i); }
		for (i = 16; i < 80; i++) { w[i] = W1(i); }
		for (i =  0; i < 80; i++) { STEP(i); }
		for (i =  0; i <  8; i++) { r[i] += S->H[i]; S->H[i] = r[i]; }
		S->T[0] += HASH_BLOCK_SIZE * 8;
		S->T[1] += (!S->T[0]) ? 1 : 0;
		in += HASH_BLOCK_SIZE;
	}
}

static void
ed25519_hash_init(sha512_state *S) {
	S->H[0] = 0x6a09e667f3bcc908ull;
	S->H[1] = 0xbb67ae8584caa73bull;
	S->H[2] = 0x3c6ef372fe94f82bull;
	S->H[3] = 0xa54ff53a5f1d36f1ull;
	S->H[4] = 0x510e527fade682d1ull;
	S->H[5] = 0x9b05688c2b3e6c1full;
	S->H[6] = 0x1f83d9abfb41bd6bull;
	S->H[7] = 0x5be0cd19137e2179ull;
	S->T[0] = 0;
	S->T[1] = 0;
	S->leftover = 0;
}

static void
ed25519_hash_update(sha512_state *S, const uint8_t *in, size_t inlen) {
	size_t blocks, want;

	/* handle the previous data */
	if (S->leftover) {
		want = (HASH_BLOCK_SIZE - S->leftover);
		want = (want < inlen) ? want : inlen;
		memcpy(S->buffer + S->leftover, in, want);
		S->leftover += (uint32_t)want;
		if (S->leftover < HASH_BLOCK_SIZE)
			return;
		in += want;
		inlen -= want;
		sha512_blocks(S, S->buffer, 1);
	}

	/* handle the current data */
	blocks = (inlen & ~(HASH_BLOCK_SIZE - 1));
	S->leftover = (uint32_t)(inlen - blocks);
	if (blocks) {
		sha512_blocks(S, in, blocks / HASH_BLOCK_SIZE);
		in += blocks;
	}

	/* handle leftover data */
	if (S->leftover)
		memcpy(S->buffer, in, S->leftover);
}

static void
ed25519_hash_final(sha512_state *S, uint8_t *hash) {
	uint64_t t0 = S->T[0] + (S->leftover * 8), t1 = S->T[1];

	S->buffer[S->leftover] = 0x80;
	if (S->leftover <= 111) {
		memset(S->buffer + S->leftover + 1, 0, 111 - S->leftover);
	} else {
		memset(S->buffer + S->leftover + 1, 0, 127 - S->leftover);
		sha512_blocks(S, S->buffer, 1);
		memset(S->buffer, 0, 112);
	}

	sha512_STORE64_BE(S->buffer + 112, t1);
	sha512_STORE64_BE(S->buffer + 120, t0);
	sha512_blocks(S, S->buffer, 1);

	sha512_STORE64_BE(&hash[ 0], S->H[0]);
	sha512_STORE64_BE(&hash[ 8], S->H[1]);
	sha512_STORE64_BE(&hash[16], S->H[2]);
	sha512_STORE64_BE(&hash[24], S->H[3]);
	sha512_STORE64_BE(&hash[32], S->H[4]);
	sha512_STORE64_BE(&hash[40], S->H[5]);
	sha512_STORE64_BE(&hash[48], S->H[6]);
	sha512_STORE64_BE(&hash[56], S->H[7]);
}

static void
ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen) {
	ed25519_hash_context ctx;
	ed25519_hash_init(&ctx);
	ed25519_hash_update(&ctx, in, inlen);
	ed25519_hash_final(&ctx, hash);
}

#elif defined(ED25519_CUSTOMHASH)

#include "ed25519-hash-custom.h"

#else

#include <openssl/sha.h>

typedef SHA512_CTX ed25519_hash_context;

static void
ed25519_hash_init(ed25519_hash_context *ctx) {
	SHA512_Init(ctx);
}

static void
ed25519_hash_update(ed25519_hash_context *ctx, const uint8_t *in, size_t inlen) {
	SHA512_Update(ctx, in, inlen);
}

static void
ed25519_hash_final(ed25519_hash_context *ctx, uint8_t *hash) {
	SHA512_Final(hash, ctx);
}

static void
ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen) {
	SHA512(in, inlen, hash);
}

#endif

