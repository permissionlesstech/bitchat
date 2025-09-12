/* Added for Tor. */
#ifndef SRC_EXT_ED25519_DONNA_H_INCLUDED_
#define SRC_EXT_ED25519_DONNA_H_INCLUDED_
#include "lib/cc/torint.h"

typedef unsigned char curved25519_key[32];

int ed25519_sign_open_batch_donna(const unsigned char **m, size_t *mlen, const unsigned char **pk, const unsigned char **RS, size_t num, int *valid);
void curved25519_scalarmult_basepoint_donna(curved25519_key pk, const curved25519_key e);

/* Tor specific interface to match the `ref10` glue code. */
int ed25519_donna_selftest(void);
int ed25519_donna_seckey(unsigned char *sk);
int ed25519_donna_seckey_expand(unsigned char *sk, const unsigned char *sk_seed);
int ed25519_donna_pubkey(unsigned char *pk, const unsigned char *sk);
int ed25519_donna_keygen(unsigned char *pk, unsigned char *sk);

int ed25519_donna_open(const unsigned char *signature, const unsigned char *m,
  size_t mlen, const unsigned char *pk);

int ed25519_donna_sign(unsigned char *sig, const unsigned char *m, size_t mlen,
  const unsigned char *sk, const unsigned char *pk);

int ed25519_donna_blind_secret_key(unsigned char *out, const unsigned char *inp,
  const unsigned char *param);

int ed25519_donna_blind_public_key(unsigned char *out, const unsigned char *inp,
  const unsigned char *param);

int ed25519_donna_pubkey_from_curve25519_pubkey(unsigned char *out,
  const unsigned char *inp, int signbit);


int
ed25519_donna_scalarmult_with_group_order(unsigned char *out,
                                          const unsigned char *pubkey);

#endif
