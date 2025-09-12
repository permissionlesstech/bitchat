#ifndef KECCAK_FIPS202_H
#define KECCAK_FIPS202_H

#include <stddef.h>
#include "lib/cc/torint.h"

#define KECCAK_MAX_RATE 200

/* Calculate the rate (block size) from the security target. */
#define KECCAK_RATE(bits) (KECCAK_MAX_RATE - (bits / 4))

/* The internal structure of a FIPS202 hash/xof instance.  Most callers
 * should treat this as an opaque structure.
 */
typedef struct keccak_state {
  uint8_t a[KECCAK_MAX_RATE];
  size_t rate;
  uint8_t delim;

  uint8_t block[KECCAK_MAX_RATE];
  size_t offset;

  uint8_t finalized : 1;
} __attribute__((aligned(8))) keccak_state;

/* Initialize a Keccak instance suitable for SHA-3 hash functions. */
int keccak_digest_init(keccak_state *s, size_t bits);

/* Feed more data into the SHA-3 hash instance. */
int keccak_digest_update(keccak_state *s, const uint8_t *buf, size_t len);

/* Calculate the SHA-3 hash digest.  The state is unmodified to support
 * calculating multiple/rolling digests.
 */
int keccak_digest_sum(const keccak_state *s, uint8_t *out, size_t outlen);

/* Initialize a Keccak instance suitable for XOFs (SHAKE-128/256). */
int keccak_xof_init(keccak_state *s, size_t bits);

/* Absorb more data into the XOF.  Must not be called after a squeeze call. */
int keccak_xof_absorb(keccak_state *s, const uint8_t *buf, size_t len);

/* Squeeze data out of the XOF. Must not attempt to absorb additional data,
 * after a squeeze has been called.
 */
int keccak_xof_squeeze(keccak_state *s, uint8_t *out, size_t outlen);

/* Clone an existing hash/XOF instance. */
void keccak_clone(keccak_state *out, const keccak_state *in);

/* Cleanse sensitive data from a given hash instance. */
void keccak_cleanse(keccak_state *s);

#define decshake(bits) \
  int shake##bits(uint8_t*, size_t, const uint8_t*, size_t);

#define decsha3(bits) \
  int sha3_##bits(uint8_t*, size_t, const uint8_t*, size_t);

decshake(128)
decshake(256)
decsha3(224)
decsha3(256)
decsha3(384)
decsha3(512)
#endif
