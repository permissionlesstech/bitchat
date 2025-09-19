/* Added for Tor */
#ifndef SRC_EXT_ED25519_REF10_H_INCLUDED_
#define SRC_EXT_ED25519_REF10_H_INCLUDED_
#include "lib/cc/torint.h"

int ed25519_ref10_seckey(unsigned char *sk);
int ed25519_ref10_seckey_expand(unsigned char *sk, const unsigned char *sk_seed);
int ed25519_ref10_pubkey(unsigned char *pk,const unsigned char *sk);
int ed25519_ref10_keygen(unsigned char *pk,unsigned char *sk);
int ed25519_ref10_open(
  const unsigned char *signature,
  const unsigned char *m, size_t mlen,
  const unsigned char *pk);
int ed25519_ref10_sign(
  unsigned char *sig,
  const unsigned char *m, size_t mlen,
  const unsigned char *sk, const unsigned char *pk);

/* Added in Tor */
int ed25519_ref10_pubkey_from_curve25519_pubkey(unsigned char *out,
                                                const unsigned char *inp,
                                                int signbit);
int ed25519_ref10_blind_secret_key(unsigned char *out,
                              const unsigned char *inp,
                              const unsigned char *param);
int ed25519_ref10_blind_public_key(unsigned char *out,
                              const unsigned char *inp,
                              const unsigned char *param);

int
ed25519_ref10_scalarmult_with_group_order(unsigned char *out,
                                          const unsigned char *pubkey);

#endif
