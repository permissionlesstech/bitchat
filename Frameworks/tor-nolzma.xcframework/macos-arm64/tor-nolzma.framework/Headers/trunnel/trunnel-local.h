
#ifndef TRUNNEL_LOCAL_H_INCLUDED
#define TRUNNEL_LOCAL_H_INCLUDED

#include "lib/crypt_ops/crypto_util.h"
#include "lib/malloc/malloc.h"
#include "lib/log/util_bug.h"

#define trunnel_malloc tor_malloc
#define trunnel_calloc tor_calloc
#define trunnel_strdup tor_strdup
#define trunnel_free_ tor_free_
#define trunnel_realloc tor_realloc
#define trunnel_reallocarray tor_reallocarray
#define trunnel_assert tor_assert
#define trunnel_memwipe(mem, len) memwipe((mem), 0, (len))
#define trunnel_abort tor_abort_

#endif
