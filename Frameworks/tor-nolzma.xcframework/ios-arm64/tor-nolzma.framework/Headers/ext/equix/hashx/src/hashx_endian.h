#ifndef ENDIAN_H
#define ENDIAN_H

#include <stdint.h>
#include <string.h>
#include "force_inline.h"

/* Argon2 Team - Begin Code */
/*
   Not an exhaustive list, but should cover the majority of modern platforms
   Additionally, the code will always be correct---this is only a performance
   tweak.
*/
#if (defined(__BYTE_ORDER__) &&                                                \
     (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)) ||                           \
    defined(__LITTLE_ENDIAN__) || defined(__ARMEL__) || defined(__MIPSEL__) || \
    defined(__AARCH64EL__) || defined(__amd64__) || defined(__i386__) ||       \
    defined(_M_IX86) || defined(_M_X64) || defined(_M_AMD64) ||                \
    defined(_M_ARM)
#define NATIVE_LITTLE_ENDIAN
#endif
/* Argon2 Team - End Code */

static FORCE_INLINE uint32_t load32(const void* src) {
#if defined(NATIVE_LITTLE_ENDIAN)
	uint32_t w;
	memcpy(&w, src, sizeof w);
	return w;
#else
	const uint8_t* p = (const uint8_t*)src;
	uint32_t w = *p++;
	w |= (uint32_t)(*p++) << 8;
	w |= (uint32_t)(*p++) << 16;
	w |= (uint32_t)(*p++) << 24;
	return w;
#endif
}

static FORCE_INLINE uint64_t load64_native(const void* src) {
	uint64_t w;
	memcpy(&w, src, sizeof w);
	return w;
}

static FORCE_INLINE uint64_t load64(const void* src) {
#if defined(NATIVE_LITTLE_ENDIAN)
	return load64_native(src);
#else
	const uint8_t* p = (const uint8_t*)src;
	uint64_t w = *p++;
	w |= (uint64_t)(*p++) << 8;
	w |= (uint64_t)(*p++) << 16;
	w |= (uint64_t)(*p++) << 24;
	w |= (uint64_t)(*p++) << 32;
	w |= (uint64_t)(*p++) << 40;
	w |= (uint64_t)(*p++) << 48;
	w |= (uint64_t)(*p++) << 56;
	return w;
#endif
}

static FORCE_INLINE void store32(void* dst, uint32_t w) {
#if defined(NATIVE_LITTLE_ENDIAN)
	memcpy(dst, &w, sizeof w);
#else
	uint8_t* p = (uint8_t*)dst;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
#endif
}

static FORCE_INLINE void store64_native(void* dst, uint64_t w) {
	memcpy(dst, &w, sizeof w);
}

static FORCE_INLINE void store64(void* dst, uint64_t w) {
#if defined(NATIVE_LITTLE_ENDIAN)
	store64_native(dst, w);
#else
	uint8_t* p = (uint8_t*)dst;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
	w >>= 8;
	*p++ = (uint8_t)w;
#endif
}
#endif
