#ifndef SIPHASH_H
#define SIPHASH_H

#include <stdint.h>

struct sipkey {
  uint64_t k0;
  uint64_t k1;
};
uint64_t siphash24(const void *src, unsigned long src_sz, const struct sipkey *key);

void siphash_set_global_key(const struct sipkey *key);
uint64_t siphash24g(const void *src, unsigned long src_sz);
void siphash_unset_global_key(void);

#endif
