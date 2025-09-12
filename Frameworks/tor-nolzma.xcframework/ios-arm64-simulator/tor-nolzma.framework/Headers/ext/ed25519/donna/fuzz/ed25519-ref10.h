#ifndef ED25519_REF10_H
#define ED25519_REF10_H

int crypto_sign_pk_ref10(unsigned char *pk,unsigned char *sk);
int crypto_sign_ref10(unsigned char *sm,unsigned long long *smlen,const unsigned char *m,unsigned long long mlen,const unsigned char *sk);
int crypto_sign_open_ref10(unsigned char *m,unsigned long long *mlen,const unsigned char *sm,unsigned long long smlen,const unsigned char *pk);

#endif /* ED25519_REF10_H */

