/*
	Public domain by Andrew M. <liquidsun@gmail.com>
	See: https://github.com/floodyberry/curve25519-donna

	SSE2 curve25519 implementation
*/

#include <emmintrin.h>
typedef __m128i xmmi;

typedef union packedelem8_t {
	unsigned char u[16];
	xmmi v;
} packedelem8;

typedef union packedelem32_t {
	uint32_t u[4];
	xmmi v;
} packedelem32;

typedef union packedelem64_t {
	uint64_t u[2];
	xmmi v;
} packedelem64;

/* 10 elements + an extra 2 to fit in 3 xmm registers */
typedef uint32_t bignum25519[12];
typedef packedelem32 packed32bignum25519[5];
typedef packedelem64 packed64bignum25519[10];

static const packedelem32 bot32bitmask = {{0xffffffff, 0x00000000, 0xffffffff, 0x00000000}};
static const packedelem32 top64bitmask = {{0x00000000, 0x00000000, 0xffffffff, 0xffffffff}};
static const packedelem32 bot64bitmask = {{0xffffffff, 0xffffffff, 0x00000000, 0x00000000}};

/* reduction masks */
static const packedelem64 packedmask26 = {{0x03ffffff, 0x03ffffff}};
static const packedelem64 packedmask25 = {{0x01ffffff, 0x01ffffff}};
static const packedelem32 packedmask26262626 = {{0x03ffffff, 0x03ffffff, 0x03ffffff, 0x03ffffff}};
static const packedelem32 packedmask25252525 = {{0x01ffffff, 0x01ffffff, 0x01ffffff, 0x01ffffff}};

/* multipliers */
static const packedelem64 packednineteen = {{19, 19}};
static const packedelem64 packedthirtyeight = {{38, 38}};
static const packedelem64 packed3819 = {{19*2,19}};

/* 2*(2^255 - 19) = 0 mod p */
static const packedelem32 packed2p0 = {{0x7ffffda,0x3fffffe,0x7fffffe,0x3fffffe}};
static const packedelem32 packed2p1 = {{0x7fffffe,0x3fffffe,0x7fffffe,0x3fffffe}};
static const packedelem32 packed2p2 = {{0x7fffffe,0x3fffffe,0x0000000,0x0000000}};

static const packedelem32 packed32packed2p0 = {{0x7ffffda,0x7ffffda,0x3fffffe,0x3fffffe}};
static const packedelem32 packed32packed2p1 = {{0x7fffffe,0x7fffffe,0x3fffffe,0x3fffffe}};

/* 4*(2^255 - 19) = 0 mod p */
static const packedelem32 packed4p0 = {{0xfffffb4,0x7fffffc,0xffffffc,0x7fffffc}};
static const packedelem32 packed4p1 = {{0xffffffc,0x7fffffc,0xffffffc,0x7fffffc}};
static const packedelem32 packed4p2 = {{0xffffffc,0x7fffffc,0x0000000,0x0000000}};

static const packedelem32 packed32packed4p0 = {{0xfffffb4,0xfffffb4,0x7fffffc,0x7fffffc}};
static const packedelem32 packed32packed4p1 = {{0xffffffc,0xffffffc,0x7fffffc,0x7fffffc}};

/* out = in */
DONNA_INLINE static void
curve25519_copy(bignum25519 out, const bignum25519 in) {
	xmmi x0,x1,x2;
	x0 = _mm_load_si128((xmmi*)in + 0);
	x1 = _mm_load_si128((xmmi*)in + 1);
	x2 = _mm_load_si128((xmmi*)in + 2);
	_mm_store_si128((xmmi*)out + 0, x0);
	_mm_store_si128((xmmi*)out + 1, x1);
	_mm_store_si128((xmmi*)out + 2, x2);
}

/* out = a + b */
DONNA_INLINE static void
curve25519_add(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	a0 = _mm_load_si128((xmmi*)a + 0);
	a1 = _mm_load_si128((xmmi*)a + 1);
	a2 = _mm_load_si128((xmmi*)a + 2);
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_add_epi32(a0, b0);
	a1 = _mm_add_epi32(a1, b1);
	a2 = _mm_add_epi32(a2, b2);
	_mm_store_si128((xmmi*)out + 0, a0);
	_mm_store_si128((xmmi*)out + 1, a1);
	_mm_store_si128((xmmi*)out + 2, a2);
}

#define curve25519_add_after_basic curve25519_add_reduce
DONNA_INLINE static void
curve25519_add_reduce(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	xmmi c1,c2,c3;
	xmmi r0,r1,r2,r3,r4,r5;

	a0 = _mm_load_si128((xmmi*)a + 0);
	a1 = _mm_load_si128((xmmi*)a + 1);
	a2 = _mm_load_si128((xmmi*)a + 2);
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_add_epi32(a0, b0);
	a1 = _mm_add_epi32(a1, b1);
	a2 = _mm_add_epi32(a2, b2);

	r0 = _mm_and_si128(_mm_unpacklo_epi64(a0, a1), bot32bitmask.v);
	r1 = _mm_srli_epi64(_mm_unpacklo_epi64(a0, a1), 32);
	r2 = _mm_and_si128(_mm_unpackhi_epi64(a0, a1), bot32bitmask.v);
	r3 = _mm_srli_epi64(_mm_unpackhi_epi64(a0, a1), 32);
	r4 = _mm_and_si128(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), bot32bitmask.v);
	r5 = _mm_srli_epi64(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), 32);

	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
	c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
	c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
	c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

	_mm_store_si128((xmmi*)out + 0, _mm_unpacklo_epi64(_mm_unpacklo_epi32(r0, r1), _mm_unpacklo_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 1, _mm_unpacklo_epi64(_mm_unpackhi_epi32(r0, r1), _mm_unpackhi_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 2, _mm_unpackhi_epi32(r4, r5));
}

DONNA_INLINE static void
curve25519_sub(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	xmmi c1,c2;
	xmmi r0,r1;

	a0 = _mm_load_si128((xmmi*)a + 0);
	a1 = _mm_load_si128((xmmi*)a + 1);
	a2 = _mm_load_si128((xmmi*)a + 2);
	a0 = _mm_add_epi32(a0, packed2p0.v);
	a1 = _mm_add_epi32(a1, packed2p1.v);
	a2 = _mm_add_epi32(a2, packed2p2.v);
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_sub_epi32(a0, b0);
	a1 = _mm_sub_epi32(a1, b1);
	a2 = _mm_sub_epi32(a2, b2);

	r0 = _mm_and_si128(_mm_shuffle_epi32(a0, _MM_SHUFFLE(2,2,0,0)), bot32bitmask.v);
	r1 = _mm_and_si128(_mm_shuffle_epi32(a0, _MM_SHUFFLE(3,3,1,1)), bot32bitmask.v);

	c1 = _mm_srli_epi32(r0, 26); 
	c2 = _mm_srli_epi32(r1, 25); 
	r0 = _mm_and_si128(r0, packedmask26.v); 
	r1 = _mm_and_si128(r1, packedmask25.v); 
	r0 = _mm_add_epi32(r0, _mm_slli_si128(c2, 8));
	r1 = _mm_add_epi32(r1, c1);

	a0 = _mm_unpacklo_epi64(_mm_unpacklo_epi32(r0, r1), _mm_unpackhi_epi32(r0, r1));
	a1 = _mm_add_epi32(a1, _mm_srli_si128(c2, 8));

	_mm_store_si128((xmmi*)out + 0, a0);
	_mm_store_si128((xmmi*)out + 1, a1);
	_mm_store_si128((xmmi*)out + 2, a2);
}

DONNA_INLINE static void
curve25519_sub_after_basic(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	xmmi c1,c2,c3;
	xmmi r0,r1,r2,r3,r4,r5;

	a0 = _mm_load_si128((xmmi*)a + 0);
	a1 = _mm_load_si128((xmmi*)a + 1);
	a2 = _mm_load_si128((xmmi*)a + 2);
	a0 = _mm_add_epi32(a0, packed4p0.v);
	a1 = _mm_add_epi32(a1, packed4p1.v);
	a2 = _mm_add_epi32(a2, packed4p2.v);
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_sub_epi32(a0, b0);
	a1 = _mm_sub_epi32(a1, b1);
	a2 = _mm_sub_epi32(a2, b2);

	r0 = _mm_and_si128(_mm_unpacklo_epi64(a0, a1), bot32bitmask.v);
	r1 = _mm_srli_epi64(_mm_unpacklo_epi64(a0, a1), 32);
	r2 = _mm_and_si128(_mm_unpackhi_epi64(a0, a1), bot32bitmask.v);
	r3 = _mm_srli_epi64(_mm_unpackhi_epi64(a0, a1), 32);
	r4 = _mm_and_si128(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), bot32bitmask.v);
	r5 = _mm_srli_epi64(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), 32);

	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
	c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
	c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
	c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

	_mm_store_si128((xmmi*)out + 0, _mm_unpacklo_epi64(_mm_unpacklo_epi32(r0, r1), _mm_unpacklo_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 1, _mm_unpacklo_epi64(_mm_unpackhi_epi32(r0, r1), _mm_unpackhi_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 2, _mm_unpackhi_epi32(r4, r5));
}

DONNA_INLINE static void
curve25519_sub_reduce(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	xmmi c1,c2,c3;
	xmmi r0,r1,r2,r3,r4,r5;

	a0 = _mm_load_si128((xmmi*)a + 0);
	a1 = _mm_load_si128((xmmi*)a + 1);
	a2 = _mm_load_si128((xmmi*)a + 2);
	a0 = _mm_add_epi32(a0, packed2p0.v);
	a1 = _mm_add_epi32(a1, packed2p1.v);
	a2 = _mm_add_epi32(a2, packed2p2.v);
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_sub_epi32(a0, b0);
	a1 = _mm_sub_epi32(a1, b1);
	a2 = _mm_sub_epi32(a2, b2);

	r0 = _mm_and_si128(_mm_unpacklo_epi64(a0, a1), bot32bitmask.v);
	r1 = _mm_srli_epi64(_mm_unpacklo_epi64(a0, a1), 32);
	r2 = _mm_and_si128(_mm_unpackhi_epi64(a0, a1), bot32bitmask.v);
	r3 = _mm_srli_epi64(_mm_unpackhi_epi64(a0, a1), 32);
	r4 = _mm_and_si128(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), bot32bitmask.v);
	r5 = _mm_srli_epi64(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), 32);

	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
	c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
	c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
	c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

	_mm_store_si128((xmmi*)out + 0, _mm_unpacklo_epi64(_mm_unpacklo_epi32(r0, r1), _mm_unpacklo_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 1, _mm_unpacklo_epi64(_mm_unpackhi_epi32(r0, r1), _mm_unpackhi_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 2, _mm_unpackhi_epi32(r4, r5));
}


DONNA_INLINE static void
curve25519_neg(bignum25519 out, const bignum25519 b) {
	xmmi a0,a1,a2,b0,b1,b2;
	xmmi c1,c2,c3;
	xmmi r0,r1,r2,r3,r4,r5;

	a0 = packed2p0.v;
	a1 = packed2p1.v;
	a2 = packed2p2.v;
	b0 = _mm_load_si128((xmmi*)b + 0);
	b1 = _mm_load_si128((xmmi*)b + 1);
	b2 = _mm_load_si128((xmmi*)b + 2);
	a0 = _mm_sub_epi32(a0, b0);
	a1 = _mm_sub_epi32(a1, b1);
	a2 = _mm_sub_epi32(a2, b2);

	r0 = _mm_and_si128(_mm_unpacklo_epi64(a0, a1), bot32bitmask.v);
	r1 = _mm_srli_epi64(_mm_unpacklo_epi64(a0, a1), 32);
	r2 = _mm_and_si128(_mm_unpackhi_epi64(a0, a1), bot32bitmask.v);
	r3 = _mm_srli_epi64(_mm_unpackhi_epi64(a0, a1), 32);
	r4 = _mm_and_si128(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), bot32bitmask.v);
	r5 = _mm_srli_epi64(_mm_unpacklo_epi64(_mm_setzero_si128(), a2), 32);

	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
	c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
	c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
	c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

	_mm_store_si128((xmmi*)out + 0, _mm_unpacklo_epi64(_mm_unpacklo_epi32(r0, r1), _mm_unpacklo_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 1, _mm_unpacklo_epi64(_mm_unpackhi_epi32(r0, r1), _mm_unpackhi_epi32(r2, r3)));
	_mm_store_si128((xmmi*)out + 2, _mm_unpackhi_epi32(r4, r5));
}


/* Multiply two numbers: out = in2 * in */
static void 
curve25519_mul(bignum25519 out, const bignum25519 r, const bignum25519 s) {
	xmmi m01,m23,m45,m67,m89;
	xmmi m0123,m4567;
	xmmi s0123,s4567;
	xmmi s01,s23,s45,s67,s89;
	xmmi s12,s34,s56,s78,s9;
	xmmi r0,r2,r4,r6,r8;
	xmmi r1,r3,r5,r7,r9;
	xmmi r119,r219,r319,r419,r519,r619,r719,r819,r919;
	xmmi c1,c2,c3;

	s0123 = _mm_load_si128((xmmi*)s + 0);
	s01 = _mm_shuffle_epi32(s0123,_MM_SHUFFLE(3,1,2,0));
	s12 = _mm_shuffle_epi32(s0123, _MM_SHUFFLE(2,2,1,1));
	s23 = _mm_shuffle_epi32(s0123,_MM_SHUFFLE(3,3,2,2));
	s4567 = _mm_load_si128((xmmi*)s + 1);
	s34 = _mm_unpacklo_epi64(_mm_srli_si128(s0123,12),s4567);
	s45 = _mm_shuffle_epi32(s4567,_MM_SHUFFLE(3,1,2,0));
	s56 = _mm_shuffle_epi32(s4567, _MM_SHUFFLE(2,2,1,1));
	s67 = _mm_shuffle_epi32(s4567,_MM_SHUFFLE(3,3,2,2));
	s89 = _mm_load_si128((xmmi*)s + 2);
	s78 = _mm_unpacklo_epi64(_mm_srli_si128(s4567,12),s89);
	s89 = _mm_shuffle_epi32(s89,_MM_SHUFFLE(3,1,2,0));
	s9 = _mm_shuffle_epi32(s89, _MM_SHUFFLE(3,3,2,2));

	r0 = _mm_load_si128((xmmi*)r + 0);
	r1 = _mm_shuffle_epi32(r0, _MM_SHUFFLE(1,1,1,1));
	r1 = _mm_add_epi64(r1, _mm_and_si128(r1, top64bitmask.v));
	r2 = _mm_shuffle_epi32(r0, _MM_SHUFFLE(2,2,2,2));
	r3 = _mm_shuffle_epi32(r0, _MM_SHUFFLE(3,3,3,3));
	r3 = _mm_add_epi64(r3, _mm_and_si128(r3, top64bitmask.v));
	r0 = _mm_shuffle_epi32(r0, _MM_SHUFFLE(0,0,0,0));
	r4 = _mm_load_si128((xmmi*)r + 1);
	r5 = _mm_shuffle_epi32(r4, _MM_SHUFFLE(1,1,1,1));
	r5 = _mm_add_epi64(r5, _mm_and_si128(r5, top64bitmask.v));
	r6 = _mm_shuffle_epi32(r4, _MM_SHUFFLE(2,2,2,2));
	r7 = _mm_shuffle_epi32(r4, _MM_SHUFFLE(3,3,3,3));
	r7 = _mm_add_epi64(r7, _mm_and_si128(r7, top64bitmask.v));
	r4 = _mm_shuffle_epi32(r4, _MM_SHUFFLE(0,0,0,0));
	r8 = _mm_load_si128((xmmi*)r + 2);
	r9 = _mm_shuffle_epi32(r8, _MM_SHUFFLE(3,1,3,1));
	r9 = _mm_add_epi64(r9, _mm_and_si128(r9, top64bitmask.v));
	r8 = _mm_shuffle_epi32(r8, _MM_SHUFFLE(3,0,3,0));

	m01 = _mm_mul_epu32(r1,s01);
	m23 = _mm_mul_epu32(r1,s23);
	m45 = _mm_mul_epu32(r1,s45);
	m67 = _mm_mul_epu32(r1,s67);
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r3,s01));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r3,s23));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r3,s45));
	m89 = _mm_mul_epu32(r1,s89);
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r5,s01));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r5,s23));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r3,s67));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r7,s01));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r5,s45));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r7,s23));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r9,s01));

	/* shift up */
	m89 = _mm_unpackhi_epi64(m67,_mm_slli_si128(m89,8));
	m67 = _mm_unpackhi_epi64(m45,_mm_slli_si128(m67,8));
	m45 = _mm_unpackhi_epi64(m23,_mm_slli_si128(m45,8));
	m23 = _mm_unpackhi_epi64(m01,_mm_slli_si128(m23,8));
	m01 = _mm_unpackhi_epi64(_mm_setzero_si128(),_mm_slli_si128(m01,8));

	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r0,s01));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r0,s23));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r0,s45));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r0,s67));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r2,s01));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r2,s23));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r4,s23));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r0,s89));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r4,s01));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r2,s45));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r2,s67));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r6,s01));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r4,s45));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r6,s23));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r8,s01));

	r219 = _mm_mul_epu32(r2, packednineteen.v);
	r419 = _mm_mul_epu32(r4, packednineteen.v);
	r619 = _mm_mul_epu32(r6, packednineteen.v);
	r819 = _mm_mul_epu32(r8, packednineteen.v);
	r119 = _mm_shuffle_epi32(r1,_MM_SHUFFLE(0,0,2,2)); r119 = _mm_mul_epu32(r119, packednineteen.v);
	r319 = _mm_shuffle_epi32(r3,_MM_SHUFFLE(0,0,2,2)); r319 = _mm_mul_epu32(r319, packednineteen.v);
	r519 = _mm_shuffle_epi32(r5,_MM_SHUFFLE(0,0,2,2)); r519 = _mm_mul_epu32(r519, packednineteen.v);
	r719 = _mm_shuffle_epi32(r7,_MM_SHUFFLE(0,0,2,2)); r719 = _mm_mul_epu32(r719, packednineteen.v);
	r919 = _mm_shuffle_epi32(r9,_MM_SHUFFLE(0,0,2,2)); r919 = _mm_mul_epu32(r919, packednineteen.v);

	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r919,s12));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r919,s34));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r919,s56));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r919,s78));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r719,s34));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r719,s56));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r719,s78));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r719,s9));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r519,s56));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r519,s78));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r519,s9));
	m67 = _mm_add_epi64(m67,_mm_mul_epu32(r819,s89));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r319,s78));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r319,s9));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r619,s89));
	m89 = _mm_add_epi64(m89,_mm_mul_epu32(r919,s9));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r819,s23));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r819,s45));
	m45 = _mm_add_epi64(m45,_mm_mul_epu32(r819,s67));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r619,s45));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r619,s67));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r419,s67));
	m23 = _mm_add_epi64(m23,_mm_mul_epu32(r419,s89));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r219,s89));
	m01 = _mm_add_epi64(m01,_mm_mul_epu32(r119,s9));

	r0 = _mm_unpacklo_epi64(m01, m45);
	r1 = _mm_unpackhi_epi64(m01, m45);
	r2 = _mm_unpacklo_epi64(m23, m67);
	r3 = _mm_unpackhi_epi64(m23, m67);
	r4 = _mm_unpacklo_epi64(m89, m89);
	r5 = _mm_unpackhi_epi64(m89, m89);

	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
	c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
	c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
	c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
	c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

	m0123 = _mm_unpacklo_epi32(r0, r1);
	m4567 = _mm_unpackhi_epi32(r0, r1);
	m0123 = _mm_unpacklo_epi64(m0123, _mm_unpacklo_epi32(r2, r3));
	m4567 = _mm_unpacklo_epi64(m4567, _mm_unpackhi_epi32(r2, r3));
	m89 = _mm_unpackhi_epi32(r4, r5);

	_mm_store_si128((xmmi*)out + 0, m0123);
	_mm_store_si128((xmmi*)out + 1, m4567);
	_mm_store_si128((xmmi*)out + 2, m89);
}

DONNA_NOINLINE static void
curve25519_mul_noinline(bignum25519 out, const bignum25519 r, const bignum25519 s) {
	curve25519_mul(out, r, s);
}

#define curve25519_square(r, n) curve25519_square_times(r, n, 1)
static void
curve25519_square_times(bignum25519 r, const bignum25519 in, int count) {
	xmmi m01,m23,m45,m67,m89;
	xmmi r0,r1,r2,r3,r4,r5,r6,r7,r8,r9;
	xmmi r0a,r1a,r2a,r3a,r7a,r9a;
	xmmi r0123,r4567;
	xmmi r01,r23,r45,r67,r6x,r89,r8x;
	xmmi r12,r34,r56,r78,r9x;
	xmmi r5619;
	xmmi c1,c2,c3;

	r0123 = _mm_load_si128((xmmi*)in + 0);
	r01 = _mm_shuffle_epi32(r0123,_MM_SHUFFLE(3,1,2,0));
	r23 = _mm_shuffle_epi32(r0123,_MM_SHUFFLE(3,3,2,2));
	r4567 = _mm_load_si128((xmmi*)in + 1);
	r45 = _mm_shuffle_epi32(r4567,_MM_SHUFFLE(3,1,2,0));
	r67 = _mm_shuffle_epi32(r4567,_MM_SHUFFLE(3,3,2,2));
	r89 = _mm_load_si128((xmmi*)in + 2);
	r89 = _mm_shuffle_epi32(r89,_MM_SHUFFLE(3,1,2,0));

	do {
		r12 = _mm_unpackhi_epi64(r01, _mm_slli_si128(r23, 8));
		r0 = _mm_shuffle_epi32(r01, _MM_SHUFFLE(0,0,0,0));
		r0 = _mm_add_epi64(r0, _mm_and_si128(r0, top64bitmask.v));
		r0a = _mm_shuffle_epi32(r0,_MM_SHUFFLE(3,2,1,2));
		r1 = _mm_shuffle_epi32(r01, _MM_SHUFFLE(2,2,2,2));
		r2 = _mm_shuffle_epi32(r23, _MM_SHUFFLE(0,0,0,0));
		r2 = _mm_add_epi64(r2, _mm_and_si128(r2, top64bitmask.v));
		r2a = _mm_shuffle_epi32(r2,_MM_SHUFFLE(3,2,1,2));
		r3 = _mm_shuffle_epi32(r23, _MM_SHUFFLE(2,2,2,2));
		r34 = _mm_unpackhi_epi64(r23, _mm_slli_si128(r45, 8));
		r4 = _mm_shuffle_epi32(r45, _MM_SHUFFLE(0,0,0,0));
		r4 = _mm_add_epi64(r4, _mm_and_si128(r4, top64bitmask.v));
		r56 = _mm_unpackhi_epi64(r45, _mm_slli_si128(r67, 8));
		r5619 = _mm_mul_epu32(r56, packednineteen.v);
		r5 = _mm_shuffle_epi32(r5619, _MM_SHUFFLE(1,1,1,0));
		r6 = _mm_shuffle_epi32(r5619, _MM_SHUFFLE(3,2,3,2));		
		r78 = _mm_unpackhi_epi64(r67, _mm_slli_si128(r89, 8));
		r6x = _mm_unpacklo_epi64(r67, _mm_setzero_si128());
		r7 = _mm_shuffle_epi32(r67, _MM_SHUFFLE(2,2,2,2));
		r7 = _mm_mul_epu32(r7, packed3819.v);
		r7a = _mm_shuffle_epi32(r7, _MM_SHUFFLE(3,3,3,2));
		r8x = _mm_unpacklo_epi64(r89, _mm_setzero_si128());
		r8 = _mm_shuffle_epi32(r89, _MM_SHUFFLE(0,0,0,0));
		r8 = _mm_mul_epu32(r8, packednineteen.v);
		r9  = _mm_shuffle_epi32(r89, _MM_SHUFFLE(2,2,2,2));
		r9x  = _mm_slli_epi32(_mm_shuffle_epi32(r89, _MM_SHUFFLE(3,3,3,2)), 1);
		r9 = _mm_mul_epu32(r9, packed3819.v);
		r9a = _mm_shuffle_epi32(r9, _MM_SHUFFLE(2,2,2,2));

		m01 = _mm_mul_epu32(r01, r0);
		m23 = _mm_mul_epu32(r23, r0a);
		m45 = _mm_mul_epu32(r45, r0a);
		m45 = _mm_add_epi64(m45, _mm_mul_epu32(r23, r2));
		r23 = _mm_slli_epi32(r23, 1);
		m67 = _mm_mul_epu32(r67, r0a);
		m67 = _mm_add_epi64(m67, _mm_mul_epu32(r45, r2a));
		m89 = _mm_mul_epu32(r89, r0a);
		m89 = _mm_add_epi64(m89, _mm_mul_epu32(r67, r2a));
		r67 = _mm_slli_epi32(r67, 1);
		m89 = _mm_add_epi64(m89, _mm_mul_epu32(r45, r4));
		r45 = _mm_slli_epi32(r45, 1);

		r1 = _mm_slli_epi32(r1, 1);
		r3 = _mm_slli_epi32(r3, 1);
		r1a = _mm_add_epi64(r1, _mm_and_si128(r1, bot64bitmask.v));
		r3a = _mm_add_epi64(r3, _mm_and_si128(r3, bot64bitmask.v));

		m23 = _mm_add_epi64(m23, _mm_mul_epu32(r12, r1));
		m45 = _mm_add_epi64(m45, _mm_mul_epu32(r34, r1a));
		m67 = _mm_add_epi64(m67, _mm_mul_epu32(r56, r1a));
		m67 = _mm_add_epi64(m67, _mm_mul_epu32(r34, r3));
		r34 = _mm_slli_epi32(r34, 1);
		m89 = _mm_add_epi64(m89, _mm_mul_epu32(r78, r1a));
		r78 = _mm_slli_epi32(r78, 1);
		m89 = _mm_add_epi64(m89, _mm_mul_epu32(r56, r3a));
		r56 = _mm_slli_epi32(r56, 1);

		m01 = _mm_add_epi64(m01, _mm_mul_epu32(_mm_slli_epi32(r12, 1), r9));
		m01 = _mm_add_epi64(m01, _mm_mul_epu32(r34, r7));
		m23 = _mm_add_epi64(m23, _mm_mul_epu32(r34, r9));
		m01 = _mm_add_epi64(m01, _mm_mul_epu32(r56, r5));
		m23 = _mm_add_epi64(m23, _mm_mul_epu32(r56, r7));
		m45 = _mm_add_epi64(m45, _mm_mul_epu32(r56, r9));
		m01 = _mm_add_epi64(m01, _mm_mul_epu32(r23, r8));
		m01 = _mm_add_epi64(m01, _mm_mul_epu32(r45, r6));
		m23 = _mm_add_epi64(m23, _mm_mul_epu32(r45, r8));
		m23 = _mm_add_epi64(m23, _mm_mul_epu32(r6x, r6));
		m45 = _mm_add_epi64(m45, _mm_mul_epu32(r78, r7a));
		m67 = _mm_add_epi64(m67, _mm_mul_epu32(r78, r9));
		m45 = _mm_add_epi64(m45, _mm_mul_epu32(r67, r8));		
		m67 = _mm_add_epi64(m67, _mm_mul_epu32(r8x, r8));
		m89 = _mm_add_epi64(m89, _mm_mul_epu32(r9x, r9a));

		r0 = _mm_unpacklo_epi64(m01, m45);
		r1 = _mm_unpackhi_epi64(m01, m45);
		r2 = _mm_unpacklo_epi64(m23, m67);
		r3 = _mm_unpackhi_epi64(m23, m67);
		r4 = _mm_unpacklo_epi64(m89, m89);
		r5 = _mm_unpackhi_epi64(m89, m89);

		c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);
		c1 = _mm_srli_epi64(r1, 25); c2 = _mm_srli_epi64(r3, 25); r1 = _mm_and_si128(r1, packedmask25.v); r3 = _mm_and_si128(r3, packedmask25.v); r2 = _mm_add_epi64(r2, c1); r4 = _mm_add_epi64(r4, c2); c3 = _mm_slli_si128(c2, 8);
		c1 = _mm_srli_epi64(r4, 26);                                                                      r4 = _mm_and_si128(r4, packedmask26.v);                             r5 = _mm_add_epi64(r5, c1); 
		c1 = _mm_srli_epi64(r5, 25);                                                                      r5 = _mm_and_si128(r5, packedmask25.v);                             r0 = _mm_add_epi64(r0, _mm_unpackhi_epi64(_mm_mul_epu32(c1, packednineteen.v), c3));
		c1 = _mm_srli_epi64(r0, 26); c2 = _mm_srli_epi64(r2, 26); r0 = _mm_and_si128(r0, packedmask26.v); r2 = _mm_and_si128(r2, packedmask26.v); r1 = _mm_add_epi64(r1, c1); r3 = _mm_add_epi64(r3, c2);

		r01 = _mm_unpacklo_epi64(r0, r1);
		r45 = _mm_unpackhi_epi64(r0, r1);
		r23 = _mm_unpacklo_epi64(r2, r3);
		r67 = _mm_unpackhi_epi64(r2, r3);
		r89 = _mm_unpackhi_epi64(r4, r5);
	} while (--count);

	r0123 = _mm_shuffle_epi32(r23, _MM_SHUFFLE(2,0,3,3));
	r4567 = _mm_shuffle_epi32(r67, _MM_SHUFFLE(2,0,3,3));
	r0123 = _mm_or_si128(r0123, _mm_shuffle_epi32(r01, _MM_SHUFFLE(3,3,2,0)));
	r4567 = _mm_or_si128(r4567, _mm_shuffle_epi32(r45, _MM_SHUFFLE(3,3,2,0)));
	r89 = _mm_shuffle_epi32(r89, _MM_SHUFFLE(3,3,2,0));

	_mm_store_si128((xmmi*)r + 0, r0123);
	_mm_store_si128((xmmi*)r + 1, r4567);
	_mm_store_si128((xmmi*)r + 2, r89);
}

DONNA_INLINE static void
curve25519_tangle32(packedelem32 *out, const bignum25519 x, const bignum25519 z) {
	xmmi x0,x1,x2,z0,z1,z2;

	x0 = _mm_load_si128((xmmi *)(x + 0));
	x1 = _mm_load_si128((xmmi *)(x + 4));
	x2 = _mm_load_si128((xmmi *)(x + 8));
	z0 = _mm_load_si128((xmmi *)(z + 0));
	z1 = _mm_load_si128((xmmi *)(z + 4));
	z2 = _mm_load_si128((xmmi *)(z + 8));

	out[0].v = _mm_unpacklo_epi32(x0, z0);
	out[1].v = _mm_unpackhi_epi32(x0, z0);
	out[2].v = _mm_unpacklo_epi32(x1, z1);
	out[3].v = _mm_unpackhi_epi32(x1, z1);
	out[4].v = _mm_unpacklo_epi32(x2, z2);
}

DONNA_INLINE static void
curve25519_untangle32(bignum25519 x, bignum25519 z, const packedelem32 *in) {
	xmmi t0,t1,t2,t3,t4,zero;

	t0 = _mm_shuffle_epi32(in[0].v, _MM_SHUFFLE(3,1,2,0));
	t1 = _mm_shuffle_epi32(in[1].v, _MM_SHUFFLE(3,1,2,0));
	t2 = _mm_shuffle_epi32(in[2].v, _MM_SHUFFLE(3,1,2,0));
	t3 = _mm_shuffle_epi32(in[3].v, _MM_SHUFFLE(3,1,2,0));
	t4 = _mm_shuffle_epi32(in[4].v, _MM_SHUFFLE(3,1,2,0));
	zero = _mm_setzero_si128();
	_mm_store_si128((xmmi *)x + 0, _mm_unpacklo_epi64(t0, t1));
	_mm_store_si128((xmmi *)x + 1, _mm_unpacklo_epi64(t2, t3));
	_mm_store_si128((xmmi *)x + 2, _mm_unpacklo_epi64(t4, zero));
	_mm_store_si128((xmmi *)z + 0, _mm_unpackhi_epi64(t0, t1));
	_mm_store_si128((xmmi *)z + 1, _mm_unpackhi_epi64(t2, t3));
	_mm_store_si128((xmmi *)z + 2, _mm_unpackhi_epi64(t4, zero));
}

DONNA_INLINE static void
curve25519_add_reduce_packed32(packedelem32 *out, const packedelem32 *r, const packedelem32 *s) {
	xmmi r0,r1,r2,r3,r4;
	xmmi s0,s1,s2,s3,s4,s5;
	xmmi c1,c2;

	r0 = _mm_add_epi32(r[0].v, s[0].v);
	r1 = _mm_add_epi32(r[1].v, s[1].v);
	r2 = _mm_add_epi32(r[2].v, s[2].v);
	r3 = _mm_add_epi32(r[3].v, s[3].v);
	r4 = _mm_add_epi32(r[4].v, s[4].v);

	s0 = _mm_unpacklo_epi64(r0, r2); /* 00 44 */
	s1 = _mm_unpackhi_epi64(r0, r2); /* 11 55 */
	s2 = _mm_unpacklo_epi64(r1, r3); /* 22 66 */
	s3 = _mm_unpackhi_epi64(r1, r3); /* 33 77 */
	s4 = _mm_unpacklo_epi64(_mm_setzero_si128(), r4);  /* 00 88 */
	s5 = _mm_unpackhi_epi64(_mm_setzero_si128(), r4);  /* 00 99 */

	c1 = _mm_srli_epi32(s0, 26); c2 = _mm_srli_epi32(s2, 26); s0 = _mm_and_si128(s0, packedmask26262626.v); s2 = _mm_and_si128(s2, packedmask26262626.v); s1 = _mm_add_epi32(s1, c1); s3 = _mm_add_epi32(s3, c2);
	c1 = _mm_srli_epi32(s1, 25); c2 = _mm_srli_epi32(s3, 25); s1 = _mm_and_si128(s1, packedmask25252525.v); s3 = _mm_and_si128(s3, packedmask25252525.v); s2 = _mm_add_epi32(s2, c1); s4 = _mm_add_epi32(s4, _mm_unpackhi_epi64(_mm_setzero_si128(), c2)); s0 = _mm_add_epi32(s0, _mm_unpacklo_epi64(_mm_setzero_si128(), c2));
	c1 = _mm_srli_epi32(s2, 26); c2 = _mm_srli_epi32(s4, 26); s2 = _mm_and_si128(s2, packedmask26262626.v); s4 = _mm_and_si128(s4, packedmask26262626.v); s3 = _mm_add_epi32(s3, c1); s5 = _mm_add_epi32(s5, c2);
	c1 = _mm_srli_epi32(s3, 25); c2 = _mm_srli_epi32(s5, 25); s3 = _mm_and_si128(s3, packedmask25252525.v); s5 = _mm_and_si128(s5, packedmask25252525.v); s4 = _mm_add_epi32(s4, c1); s0 = _mm_add_epi32(s0, _mm_or_si128(_mm_slli_si128(c1, 8), _mm_srli_si128(_mm_add_epi32(_mm_add_epi32(_mm_slli_epi32(c2, 4), _mm_slli_epi32(c2, 1)), c2), 8)));
	c1 = _mm_srli_epi32(s0, 26); c2 = _mm_srli_epi32(s2, 26); s0 = _mm_and_si128(s0, packedmask26262626.v); s2 = _mm_and_si128(s2, packedmask26262626.v); s1 = _mm_add_epi32(s1, c1); s3 = _mm_add_epi32(s3, c2);

	out[0].v = _mm_unpacklo_epi64(s0, s1); /* 00 11 */
	out[1].v = _mm_unpacklo_epi64(s2, s3); /* 22 33 */
	out[2].v = _mm_unpackhi_epi64(s0, s1); /* 44 55 */
	out[3].v = _mm_unpackhi_epi64(s2, s3); /* 66 77 */
	out[4].v = _mm_unpackhi_epi64(s4, s5); /* 88 99 */
}

DONNA_INLINE static void
curve25519_add_packed32(packedelem32 *out, const packedelem32 *r, const packedelem32 *s) {
	out[0].v = _mm_add_epi32(r[0].v, s[0].v);
	out[1].v = _mm_add_epi32(r[1].v, s[1].v);
	out[2].v = _mm_add_epi32(r[2].v, s[2].v);
	out[3].v = _mm_add_epi32(r[3].v, s[3].v);
	out[4].v = _mm_add_epi32(r[4].v, s[4].v);
}

DONNA_INLINE static void
curve25519_sub_packed32(packedelem32 *out, const packedelem32 *r, const packedelem32 *s) {
	xmmi r0,r1,r2,r3,r4;
	xmmi s0,s1,s2,s3;
	xmmi c1,c2;

	r0 = _mm_add_epi32(r[0].v, packed32packed2p0.v);
	r1 = _mm_add_epi32(r[1].v, packed32packed2p1.v);
	r2 = _mm_add_epi32(r[2].v, packed32packed2p1.v);
	r3 = _mm_add_epi32(r[3].v, packed32packed2p1.v);
	r4 = _mm_add_epi32(r[4].v, packed32packed2p1.v);
	r0 = _mm_sub_epi32(r0, s[0].v); /* 00 11 */
	r1 = _mm_sub_epi32(r1, s[1].v); /* 22 33 */
	r2 = _mm_sub_epi32(r2, s[2].v); /* 44 55 */
	r3 = _mm_sub_epi32(r3, s[3].v); /* 66 77 */
	r4 = _mm_sub_epi32(r4, s[4].v); /* 88 99 */

	s0 = _mm_unpacklo_epi64(r0, r2); /* 00 44 */
	s1 = _mm_unpackhi_epi64(r0, r2); /* 11 55 */
	s2 = _mm_unpacklo_epi64(r1, r3); /* 22 66 */
	s3 = _mm_unpackhi_epi64(r1, r3); /* 33 77 */

	c1 = _mm_srli_epi32(s0, 26); c2 = _mm_srli_epi32(s2, 26); s0 = _mm_and_si128(s0, packedmask26262626.v); s2 = _mm_and_si128(s2, packedmask26262626.v); s1 = _mm_add_epi32(s1, c1); s3 = _mm_add_epi32(s3, c2);
	c1 = _mm_srli_epi32(s1, 25); c2 = _mm_srli_epi32(s3, 25); s1 = _mm_and_si128(s1, packedmask25252525.v); s3 = _mm_and_si128(s3, packedmask25252525.v); s2 = _mm_add_epi32(s2, c1); r4 = _mm_add_epi32(r4, _mm_srli_si128(c2, 8)); s0 = _mm_add_epi32(s0,  _mm_slli_si128(c2, 8));

	out[0].v = _mm_unpacklo_epi64(s0, s1); /* 00 11 */
	out[1].v = _mm_unpacklo_epi64(s2, s3); /* 22 33 */
	out[2].v = _mm_unpackhi_epi64(s0, s1); /* 44 55 */
	out[3].v = _mm_unpackhi_epi64(s2, s3); /* 66 77 */
	out[4].v = r4;
}

DONNA_INLINE static void
curve25519_sub_after_basic_packed32(packedelem32 *out, const packedelem32 *r, const packedelem32 *s) {
	xmmi r0,r1,r2,r3,r4;
	xmmi s0,s1,s2,s3,s4,s5;
	xmmi c1,c2;

	r0 = _mm_add_epi32(r[0].v, packed32packed4p0.v);
	r1 = _mm_add_epi32(r[1].v, packed32packed4p1.v);
	r2 = _mm_add_epi32(r[2].v, packed32packed4p1.v);
	r3 = _mm_add_epi32(r[3].v, packed32packed4p1.v);
	r4 = _mm_add_epi32(r[4].v, packed32packed4p1.v);
	r0 = _mm_sub_epi32(r0, s[0].v); /* 00 11 */
	r1 = _mm_sub_epi32(r1, s[1].v); /* 22 33 */
	r2 = _mm_sub_epi32(r2, s[2].v); /* 44 55 */
	r3 = _mm_sub_epi32(r3, s[3].v); /* 66 77 */
	r4 = _mm_sub_epi32(r4, s[4].v); /* 88 99 */

	s0 = _mm_unpacklo_epi64(r0, r2); /* 00 44 */
	s1 = _mm_unpackhi_epi64(r0, r2); /* 11 55 */
	s2 = _mm_unpacklo_epi64(r1, r3); /* 22 66 */
	s3 = _mm_unpackhi_epi64(r1, r3); /* 33 77 */
	s4 = _mm_unpacklo_epi64(_mm_setzero_si128(), r4);  /* 00 88 */
	s5 = _mm_unpackhi_epi64(_mm_setzero_si128(), r4);  /* 00 99 */

	c1 = _mm_srli_epi32(s0, 26); c2 = _mm_srli_epi32(s2, 26); s0 = _mm_and_si128(s0, packedmask26262626.v); s2 = _mm_and_si128(s2, packedmask26262626.v); s1 = _mm_add_epi32(s1, c1); s3 = _mm_add_epi32(s3, c2);
	c1 = _mm_srli_epi32(s1, 25); c2 = _mm_srli_epi32(s3, 25); s1 = _mm_and_si128(s1, packedmask25252525.v); s3 = _mm_and_si128(s3, packedmask25252525.v); s2 = _mm_add_epi32(s2, c1); s4 = _mm_add_epi32(s4, _mm_unpackhi_epi64(_mm_setzero_si128(), c2)); s0 = _mm_add_epi32(s0, _mm_unpacklo_epi64(_mm_setzero_si128(), c2));
	c1 = _mm_srli_epi32(s2, 26); c2 = _mm_srli_epi32(s4, 26); s2 = _mm_and_si128(s2, packedmask26262626.v); s4 = _mm_and_si128(s4, packedmask26262626.v); s3 = _mm_add_epi32(s3, c1); s5 = _mm_add_epi32(s5, c2);
	c1 = _mm_srli_epi32(s3, 25); c2 = _mm_srli_epi32(s5, 25); s3 = _mm_and_si128(s3, packedmask25252525.v); s5 = _mm_and_si128(s5, packedmask25252525.v); s4 = _mm_add_epi32(s4, c1); s0 = _mm_add_epi32(s0, _mm_or_si128(_mm_slli_si128(c1, 8), _mm_srli_si128(_mm_add_epi32(_mm_add_epi32(_mm_slli_epi32(c2, 4), _mm_slli_epi32(c2, 1)), c2), 8)));
	c1 = _mm_srli_epi32(s0, 26); c2 = _mm_srli_epi32(s2, 26); s0 = _mm_and_si128(s0, packedmask26262626.v); s2 = _mm_and_si128(s2, packedmask26262626.v); s1 = _mm_add_epi32(s1, c1); s3 = _mm_add_epi32(s3, c2);

	out[0].v = _mm_unpacklo_epi64(s0, s1); /* 00 11 */
	out[1].v = _mm_unpacklo_epi64(s2, s3); /* 22 33 */
	out[2].v = _mm_unpackhi_epi64(s0, s1); /* 44 55 */
	out[3].v = _mm_unpackhi_epi64(s2, s3); /* 66 77 */
	out[4].v = _mm_unpackhi_epi64(s4, s5); /* 88 99 */
}

DONNA_INLINE static void
curve25519_tangle64_from32(packedelem64 *a, packedelem64 *b, const packedelem32 *c, const packedelem32 *d) {
	xmmi c0,c1,c2,c3,c4,c5,t;
	xmmi d0,d1,d2,d3,d4,d5;
	xmmi t0,t1,t2,t3,t4,zero;

	t0 = _mm_shuffle_epi32(c[0].v, _MM_SHUFFLE(3,1,2,0));
	t1 = _mm_shuffle_epi32(c[1].v, _MM_SHUFFLE(3,1,2,0));
	t2 = _mm_shuffle_epi32(d[0].v, _MM_SHUFFLE(3,1,2,0));
	t3 = _mm_shuffle_epi32(d[1].v, _MM_SHUFFLE(3,1,2,0));
	c0 = _mm_unpacklo_epi64(t0, t1);
	c3 = _mm_unpackhi_epi64(t0, t1);
	d0 = _mm_unpacklo_epi64(t2, t3);
	d3 = _mm_unpackhi_epi64(t2, t3);
	t = _mm_unpacklo_epi64(c0, d0); a[0].v = t; a[1].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(c0, d0); a[2].v = t; a[3].v = _mm_srli_epi64(t, 32);
	t = _mm_unpacklo_epi64(c3, d3); b[0].v = t; b[1].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(c3, d3); b[2].v = t; b[3].v = _mm_srli_epi64(t, 32);

	t0 = _mm_shuffle_epi32(c[2].v, _MM_SHUFFLE(3,1,2,0));
	t1 = _mm_shuffle_epi32(c[3].v, _MM_SHUFFLE(3,1,2,0));
	t2 = _mm_shuffle_epi32(d[2].v, _MM_SHUFFLE(3,1,2,0));
	t3 = _mm_shuffle_epi32(d[3].v, _MM_SHUFFLE(3,1,2,0));
	c1 = _mm_unpacklo_epi64(t0, t1);
	c4 = _mm_unpackhi_epi64(t0, t1);
	d1 = _mm_unpacklo_epi64(t2, t3);
	d4 = _mm_unpackhi_epi64(t2, t3);
	t = _mm_unpacklo_epi64(c1, d1); a[4].v = t; a[5].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(c1, d1); a[6].v = t; a[7].v = _mm_srli_epi64(t, 32);
	t = _mm_unpacklo_epi64(c4, d4); b[4].v = t; b[5].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(c4, d4); b[6].v = t; b[7].v = _mm_srli_epi64(t, 32);

	t4 = _mm_shuffle_epi32(c[4].v, _MM_SHUFFLE(3,1,2,0));
	zero = _mm_setzero_si128();
	c2 = _mm_unpacklo_epi64(t4, zero);
	c5 = _mm_unpackhi_epi64(t4, zero);
	t4 = _mm_shuffle_epi32(d[4].v, _MM_SHUFFLE(3,1,2,0));
	d2 = _mm_unpacklo_epi64(t4, zero);
	d5 = _mm_unpackhi_epi64(t4, zero);
	t = _mm_unpacklo_epi64(c2, d2); a[8].v = t; a[9].v = _mm_srli_epi64(t, 32);
	t = _mm_unpacklo_epi64(c5, d5); b[8].v = t; b[9].v = _mm_srli_epi64(t, 32);
}

DONNA_INLINE static void
curve25519_tangle64(packedelem64 *out, const bignum25519 x, const bignum25519 z) {
	xmmi x0,x1,x2,z0,z1,z2,t;

	x0 = _mm_load_si128((xmmi *)x + 0);
	x1 = _mm_load_si128((xmmi *)x + 1);
	x2 = _mm_load_si128((xmmi *)x + 2);
	z0 = _mm_load_si128((xmmi *)z + 0);
	z1 = _mm_load_si128((xmmi *)z + 1);
	z2 = _mm_load_si128((xmmi *)z + 2);

	t = _mm_unpacklo_epi64(x0, z0);	out[0].v = t; out[1].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(x0, z0);	out[2].v = t; out[3].v = _mm_srli_epi64(t, 32);
	t = _mm_unpacklo_epi64(x1, z1);	out[4].v = t; out[5].v = _mm_srli_epi64(t, 32);
	t = _mm_unpackhi_epi64(x1, z1);	out[6].v = t; out[7].v = _mm_srli_epi64(t, 32);
	t = _mm_unpacklo_epi64(x2, z2);	out[8].v = t; out[9].v = _mm_srli_epi64(t, 32);
}

DONNA_INLINE static void
curve25519_tangleone64(packedelem64 *out, const bignum25519 x) {
	xmmi x0,x1,x2;

	x0 = _mm_load_si128((xmmi *)(x + 0));
	x1 = _mm_load_si128((xmmi *)(x + 4));
	x2 = _mm_load_si128((xmmi *)(x + 8));

	out[0].v = _mm_shuffle_epi32(x0, _MM_SHUFFLE(0,0,0,0));
	out[1].v = _mm_shuffle_epi32(x0, _MM_SHUFFLE(1,1,1,1));
	out[2].v = _mm_shuffle_epi32(x0, _MM_SHUFFLE(2,2,2,2));
	out[3].v = _mm_shuffle_epi32(x0, _MM_SHUFFLE(3,3,3,3));
	out[4].v = _mm_shuffle_epi32(x1, _MM_SHUFFLE(0,0,0,0));
	out[5].v = _mm_shuffle_epi32(x1, _MM_SHUFFLE(1,1,1,1));
	out[6].v = _mm_shuffle_epi32(x1, _MM_SHUFFLE(2,2,2,2));
	out[7].v = _mm_shuffle_epi32(x1, _MM_SHUFFLE(3,3,3,3));
	out[8].v = _mm_shuffle_epi32(x2, _MM_SHUFFLE(0,0,0,0));
	out[9].v = _mm_shuffle_epi32(x2, _MM_SHUFFLE(1,1,1,1));
}

DONNA_INLINE static void
curve25519_swap64(packedelem64 *out) {
	out[0].v = _mm_shuffle_epi32(out[0].v, _MM_SHUFFLE(1,0,3,2));
	out[1].v = _mm_shuffle_epi32(out[1].v, _MM_SHUFFLE(1,0,3,2));
	out[2].v = _mm_shuffle_epi32(out[2].v, _MM_SHUFFLE(1,0,3,2));
	out[3].v = _mm_shuffle_epi32(out[3].v, _MM_SHUFFLE(1,0,3,2));
	out[4].v = _mm_shuffle_epi32(out[4].v, _MM_SHUFFLE(1,0,3,2));
	out[5].v = _mm_shuffle_epi32(out[5].v, _MM_SHUFFLE(1,0,3,2));
	out[6].v = _mm_shuffle_epi32(out[6].v, _MM_SHUFFLE(1,0,3,2));
	out[7].v = _mm_shuffle_epi32(out[7].v, _MM_SHUFFLE(1,0,3,2));
	out[8].v = _mm_shuffle_epi32(out[8].v, _MM_SHUFFLE(1,0,3,2));
	out[9].v = _mm_shuffle_epi32(out[9].v, _MM_SHUFFLE(1,0,3,2));
}

DONNA_INLINE static void
curve25519_untangle64(bignum25519 x, bignum25519 z, const packedelem64 *in) {
	_mm_store_si128((xmmi *)(x + 0), _mm_unpacklo_epi64(_mm_unpacklo_epi32(in[0].v, in[1].v), _mm_unpacklo_epi32(in[2].v, in[3].v)));
	_mm_store_si128((xmmi *)(x + 4), _mm_unpacklo_epi64(_mm_unpacklo_epi32(in[4].v, in[5].v), _mm_unpacklo_epi32(in[6].v, in[7].v)));
	_mm_store_si128((xmmi *)(x + 8), _mm_unpacklo_epi32(in[8].v, in[9].v)                                                          );
	_mm_store_si128((xmmi *)(z + 0), _mm_unpacklo_epi64(_mm_unpackhi_epi32(in[0].v, in[1].v), _mm_unpackhi_epi32(in[2].v, in[3].v)));
	_mm_store_si128((xmmi *)(z + 4), _mm_unpacklo_epi64(_mm_unpackhi_epi32(in[4].v, in[5].v), _mm_unpackhi_epi32(in[6].v, in[7].v)));
	_mm_store_si128((xmmi *)(z + 8), _mm_unpackhi_epi32(in[8].v, in[9].v)                                                          );
}

DONNA_INLINE static void
curve25519_mul_packed64(packedelem64 *out, const packedelem64 *r, const packedelem64 *s) {
	xmmi r1,r2,r3,r4,r5,r6,r7,r8,r9;
	xmmi r1_2,r3_2,r5_2,r7_2,r9_2;
	xmmi c1,c2;

	out[0].v = _mm_mul_epu32(r[0].v, s[0].v);
	out[1].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[1].v), _mm_mul_epu32(r[1].v, s[0].v));
	r1_2 = _mm_slli_epi32(r[1].v, 1);
	out[2].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r1_2  , s[1].v), _mm_mul_epu32(r[2].v, s[0].v)));
	out[3].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[3].v), _mm_add_epi64(_mm_mul_epu32(r[1].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[1].v), _mm_mul_epu32(r[3].v, s[0].v))));
	r3_2 = _mm_slli_epi32(r[3].v, 1);
	out[4].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r1_2  , s[3].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r3_2  , s[1].v), _mm_mul_epu32(r[4].v, s[0].v)))));
	out[5].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[5].v), _mm_add_epi64(_mm_mul_epu32(r[1].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[3].v), _mm_add_epi64(_mm_mul_epu32(r[3].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r[4].v, s[1].v), _mm_mul_epu32(r[5].v, s[0].v))))));
	r5_2 = _mm_slli_epi32(r[5].v, 1);
	out[6].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[6].v), _mm_add_epi64(_mm_mul_epu32(r1_2  , s[5].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r3_2  , s[3].v), _mm_add_epi64(_mm_mul_epu32(r[4].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r5_2  , s[1].v), _mm_mul_epu32(r[6].v, s[0].v)))))));
	out[7].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[7].v), _mm_add_epi64(_mm_mul_epu32(r[1].v, s[6].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[5].v), _mm_add_epi64(_mm_mul_epu32(r[3].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r[4].v, s[3].v), _mm_add_epi64(_mm_mul_epu32(r[5].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r[6].v, s[1].v), _mm_mul_epu32(r[7].v  , s[0].v))))))));
	r7_2 = _mm_slli_epi32(r[7].v, 1);
	out[8].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[8].v), _mm_add_epi64(_mm_mul_epu32(r1_2  , s[7].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[6].v), _mm_add_epi64(_mm_mul_epu32(r3_2  , s[5].v), _mm_add_epi64(_mm_mul_epu32(r[4].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r5_2  , s[3].v), _mm_add_epi64(_mm_mul_epu32(r[6].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r7_2  , s[1].v), _mm_mul_epu32(r[8].v, s[0].v)))))))));
	out[9].v = _mm_add_epi64(_mm_mul_epu32(r[0].v, s[9].v), _mm_add_epi64(_mm_mul_epu32(r[1].v, s[8].v), _mm_add_epi64(_mm_mul_epu32(r[2].v, s[7].v), _mm_add_epi64(_mm_mul_epu32(r[3].v, s[6].v), _mm_add_epi64(_mm_mul_epu32(r[4].v, s[5].v), _mm_add_epi64(_mm_mul_epu32(r[5].v, s[4].v), _mm_add_epi64(_mm_mul_epu32(r[6].v, s[3].v), _mm_add_epi64(_mm_mul_epu32(r[7].v, s[2].v), _mm_add_epi64(_mm_mul_epu32(r[8].v, s[1].v), _mm_mul_epu32(r[9].v, s[0].v))))))))));

	r1 = _mm_mul_epu32(r[1].v, packednineteen.v);
	r2 = _mm_mul_epu32(r[2].v, packednineteen.v);
	r1_2 = _mm_slli_epi32(r1, 1);
	r3 = _mm_mul_epu32(r[3].v, packednineteen.v);
	r4 = _mm_mul_epu32(r[4].v, packednineteen.v);
	r3_2 = _mm_slli_epi32(r3, 1);
	r5 = _mm_mul_epu32(r[5].v, packednineteen.v);
	r6 = _mm_mul_epu32(r[6].v, packednineteen.v);
	r5_2 = _mm_slli_epi32(r5, 1);
	r7 = _mm_mul_epu32(r[7].v, packednineteen.v);
	r8 = _mm_mul_epu32(r[8].v, packednineteen.v);
	r7_2 = _mm_slli_epi32(r7, 1);
	r9 = _mm_mul_epu32(r[9].v, packednineteen.v);
	r9_2 = _mm_slli_epi32(r9, 1);

	out[0].v = _mm_add_epi64(out[0].v, _mm_add_epi64(_mm_mul_epu32(r9_2, s[1].v), _mm_add_epi64(_mm_mul_epu32(r8, s[2].v), _mm_add_epi64(_mm_mul_epu32(r7_2, s[3].v), _mm_add_epi64(_mm_mul_epu32(r6, s[4].v), _mm_add_epi64(_mm_mul_epu32(r5_2, s[5].v), _mm_add_epi64(_mm_mul_epu32(r4, s[6].v), _mm_add_epi64(_mm_mul_epu32(r3_2, s[7].v), _mm_add_epi64(_mm_mul_epu32(r2, s[8].v), _mm_mul_epu32(r1_2, s[9].v))))))))));
	out[1].v = _mm_add_epi64(out[1].v, _mm_add_epi64(_mm_mul_epu32(r9  , s[2].v), _mm_add_epi64(_mm_mul_epu32(r8, s[3].v), _mm_add_epi64(_mm_mul_epu32(r7  , s[4].v), _mm_add_epi64(_mm_mul_epu32(r6, s[5].v), _mm_add_epi64(_mm_mul_epu32(r5  , s[6].v), _mm_add_epi64(_mm_mul_epu32(r4, s[7].v), _mm_add_epi64(_mm_mul_epu32(r3  , s[8].v), _mm_mul_epu32(r2, s[9].v)))))))));
	out[2].v = _mm_add_epi64(out[2].v, _mm_add_epi64(_mm_mul_epu32(r9_2, s[3].v), _mm_add_epi64(_mm_mul_epu32(r8, s[4].v), _mm_add_epi64(_mm_mul_epu32(r7_2, s[5].v), _mm_add_epi64(_mm_mul_epu32(r6, s[6].v), _mm_add_epi64(_mm_mul_epu32(r5_2, s[7].v), _mm_add_epi64(_mm_mul_epu32(r4, s[8].v), _mm_mul_epu32(r3_2, s[9].v))))))));
	out[3].v = _mm_add_epi64(out[3].v, _mm_add_epi64(_mm_mul_epu32(r9  , s[4].v), _mm_add_epi64(_mm_mul_epu32(r8, s[5].v), _mm_add_epi64(_mm_mul_epu32(r7  , s[6].v), _mm_add_epi64(_mm_mul_epu32(r6, s[7].v), _mm_add_epi64(_mm_mul_epu32(r5  , s[8].v), _mm_mul_epu32(r4, s[9].v)))))));
	out[4].v = _mm_add_epi64(out[4].v, _mm_add_epi64(_mm_mul_epu32(r9_2, s[5].v), _mm_add_epi64(_mm_mul_epu32(r8, s[6].v), _mm_add_epi64(_mm_mul_epu32(r7_2, s[7].v), _mm_add_epi64(_mm_mul_epu32(r6, s[8].v), _mm_mul_epu32(r5_2, s[9].v))))));
	out[5].v = _mm_add_epi64(out[5].v, _mm_add_epi64(_mm_mul_epu32(r9  , s[6].v), _mm_add_epi64(_mm_mul_epu32(r8, s[7].v), _mm_add_epi64(_mm_mul_epu32(r7  , s[8].v), _mm_mul_epu32(r6, s[9].v)))));
	out[6].v = _mm_add_epi64(out[6].v, _mm_add_epi64(_mm_mul_epu32(r9_2, s[7].v), _mm_add_epi64(_mm_mul_epu32(r8, s[8].v), _mm_mul_epu32(r7_2, s[9].v))));
	out[7].v = _mm_add_epi64(out[7].v, _mm_add_epi64(_mm_mul_epu32(r9  , s[8].v), _mm_mul_epu32(r8, s[9].v)));
	out[8].v = _mm_add_epi64(out[8].v, _mm_mul_epu32(r9_2, s[9].v));

	c1 = _mm_srli_epi64(out[0].v, 26); c2 = _mm_srli_epi64(out[4].v, 26); out[0].v = _mm_and_si128(out[0].v, packedmask26.v); out[4].v = _mm_and_si128(out[4].v, packedmask26.v); out[1].v = _mm_add_epi64(out[1].v, c1); out[5].v = _mm_add_epi64(out[5].v, c2);
	c1 = _mm_srli_epi64(out[1].v, 25); c2 = _mm_srli_epi64(out[5].v, 25); out[1].v = _mm_and_si128(out[1].v, packedmask25.v); out[5].v = _mm_and_si128(out[5].v, packedmask25.v); out[2].v = _mm_add_epi64(out[2].v, c1); out[6].v = _mm_add_epi64(out[6].v, c2);
	c1 = _mm_srli_epi64(out[2].v, 26); c2 = _mm_srli_epi64(out[6].v, 26); out[2].v = _mm_and_si128(out[2].v, packedmask26.v); out[6].v = _mm_and_si128(out[6].v, packedmask26.v); out[3].v = _mm_add_epi64(out[3].v, c1); out[7].v = _mm_add_epi64(out[7].v, c2);
	c1 = _mm_srli_epi64(out[3].v, 25); c2 = _mm_srli_epi64(out[7].v, 25); out[3].v = _mm_and_si128(out[3].v, packedmask25.v); out[7].v = _mm_and_si128(out[7].v, packedmask25.v); out[4].v = _mm_add_epi64(out[4].v, c1); out[8].v = _mm_add_epi64(out[8].v, c2);
	                                   c2 = _mm_srli_epi64(out[8].v, 26);                                                     out[8].v = _mm_and_si128(out[8].v, packedmask26.v);                                         out[9].v = _mm_add_epi64(out[9].v, c2);
	                                   c2 = _mm_srli_epi64(out[9].v, 25);                                                     out[9].v = _mm_and_si128(out[9].v, packedmask25.v);                                         out[0].v = _mm_add_epi64(out[0].v, _mm_mul_epu32(c2, packednineteen.v));
	c1 = _mm_srli_epi64(out[0].v, 26); c2 = _mm_srli_epi64(out[4].v, 26); out[0].v = _mm_and_si128(out[0].v, packedmask26.v); out[4].v = _mm_and_si128(out[4].v, packedmask26.v); out[1].v = _mm_add_epi64(out[1].v, c1); out[5].v = _mm_add_epi64(out[5].v, c2);
}

DONNA_INLINE static void
curve25519_square_packed64(packedelem64 *out, const packedelem64 *r) {
	xmmi r0,r1,r2,r3;
	xmmi r1_2,r3_2,r4_2,r5_2,r6_2,r7_2;
	xmmi d5,d6,d7,d8,d9;
	xmmi c1,c2;

	r0 = r[0].v;
	r1 = r[1].v;
	r2 = r[2].v;
	r3 = r[3].v;

	out[0].v = _mm_mul_epu32(r0, r0);
	r0 = _mm_slli_epi32(r0, 1);
	out[1].v = _mm_mul_epu32(r0, r1);
	r1_2 = _mm_slli_epi32(r1, 1);
	out[2].v = _mm_add_epi64(_mm_mul_epu32(r0, r2    ), _mm_mul_epu32(r1, r1_2));
	r1 = r1_2;
	out[3].v = _mm_add_epi64(_mm_mul_epu32(r0, r3    ), _mm_mul_epu32(r1, r2  ));
	r3_2 = _mm_slli_epi32(r3, 1);
	out[4].v = _mm_add_epi64(_mm_mul_epu32(r0, r[4].v), _mm_add_epi64(_mm_mul_epu32(r1, r3_2  ), _mm_mul_epu32(r2, r2)));
	r2 = _mm_slli_epi32(r2, 1);
	out[5].v = _mm_add_epi64(_mm_mul_epu32(r0, r[5].v), _mm_add_epi64(_mm_mul_epu32(r1, r[4].v), _mm_mul_epu32(r2, r3)));
	r5_2 = _mm_slli_epi32(r[5].v, 1);
	out[6].v = _mm_add_epi64(_mm_mul_epu32(r0, r[6].v), _mm_add_epi64(_mm_mul_epu32(r1, r5_2  ), _mm_add_epi64(_mm_mul_epu32(r2, r[4].v), _mm_mul_epu32(r3, r3_2  ))));
	r3 = r3_2;
	out[7].v = _mm_add_epi64(_mm_mul_epu32(r0, r[7].v), _mm_add_epi64(_mm_mul_epu32(r1, r[6].v), _mm_add_epi64(_mm_mul_epu32(r2, r[5].v), _mm_mul_epu32(r3, r[4].v))));
	r7_2 = _mm_slli_epi32(r[7].v, 1);
	out[8].v = _mm_add_epi64(_mm_mul_epu32(r0, r[8].v), _mm_add_epi64(_mm_mul_epu32(r1, r7_2  ), _mm_add_epi64(_mm_mul_epu32(r2, r[6].v), _mm_add_epi64(_mm_mul_epu32(r3, r5_2  ), _mm_mul_epu32(r[4].v, r[4].v)))));
	out[9].v = _mm_add_epi64(_mm_mul_epu32(r0, r[9].v), _mm_add_epi64(_mm_mul_epu32(r1, r[8].v), _mm_add_epi64(_mm_mul_epu32(r2, r[7].v), _mm_add_epi64(_mm_mul_epu32(r3, r[6].v), _mm_mul_epu32(r[4].v, r5_2  )))));

	d5 = _mm_mul_epu32(r[5].v, packedthirtyeight.v);
	d6 = _mm_mul_epu32(r[6].v, packednineteen.v);
	d7 = _mm_mul_epu32(r[7].v, packedthirtyeight.v);
	d8 = _mm_mul_epu32(r[8].v, packednineteen.v);
	d9 = _mm_mul_epu32(r[9].v, packedthirtyeight.v);

	r4_2 = _mm_slli_epi32(r[4].v, 1);
	r6_2 = _mm_slli_epi32(r[6].v, 1);
	out[0].v = _mm_add_epi64(out[0].v, _mm_add_epi64(_mm_mul_epu32(d9, r1                   ), _mm_add_epi64(_mm_mul_epu32(d8, r2  ), _mm_add_epi64(_mm_mul_epu32(d7, r3    ), _mm_add_epi64(_mm_mul_epu32(d6, r4_2), _mm_mul_epu32(d5, r[5].v))))));
	out[1].v = _mm_add_epi64(out[1].v, _mm_add_epi64(_mm_mul_epu32(d9, _mm_srli_epi32(r2, 1)), _mm_add_epi64(_mm_mul_epu32(d8, r3  ), _mm_add_epi64(_mm_mul_epu32(d7, r[4].v), _mm_mul_epu32(d6, r5_2  )))));
	out[2].v = _mm_add_epi64(out[2].v, _mm_add_epi64(_mm_mul_epu32(d9, r3                   ), _mm_add_epi64(_mm_mul_epu32(d8, r4_2), _mm_add_epi64(_mm_mul_epu32(d7, r5_2  ), _mm_mul_epu32(d6, r[6].v)))));
	out[3].v = _mm_add_epi64(out[3].v, _mm_add_epi64(_mm_mul_epu32(d9, r[4].v               ), _mm_add_epi64(_mm_mul_epu32(d8, r5_2), _mm_mul_epu32(d7, r[6].v))));
	out[4].v = _mm_add_epi64(out[4].v, _mm_add_epi64(_mm_mul_epu32(d9, r5_2                 ), _mm_add_epi64(_mm_mul_epu32(d8, r6_2), _mm_mul_epu32(d7, r[7].v))));
	out[5].v = _mm_add_epi64(out[5].v, _mm_add_epi64(_mm_mul_epu32(d9, r[6].v               ), _mm_mul_epu32(d8, r7_2  )));
	out[6].v = _mm_add_epi64(out[6].v, _mm_add_epi64(_mm_mul_epu32(d9, r7_2                 ), _mm_mul_epu32(d8, r[8].v)));
	out[7].v = _mm_add_epi64(out[7].v, _mm_mul_epu32(d9, r[8].v));
	out[8].v = _mm_add_epi64(out[8].v, _mm_mul_epu32(d9, r[9].v));

	c1 = _mm_srli_epi64(out[0].v, 26); c2 = _mm_srli_epi64(out[4].v, 26); out[0].v = _mm_and_si128(out[0].v, packedmask26.v); out[4].v = _mm_and_si128(out[4].v, packedmask26.v); out[1].v = _mm_add_epi64(out[1].v, c1); out[5].v = _mm_add_epi64(out[5].v, c2);
	c1 = _mm_srli_epi64(out[1].v, 25); c2 = _mm_srli_epi64(out[5].v, 25); out[1].v = _mm_and_si128(out[1].v, packedmask25.v); out[5].v = _mm_and_si128(out[5].v, packedmask25.v); out[2].v = _mm_add_epi64(out[2].v, c1); out[6].v = _mm_add_epi64(out[6].v, c2);
	c1 = _mm_srli_epi64(out[2].v, 26); c2 = _mm_srli_epi64(out[6].v, 26); out[2].v = _mm_and_si128(out[2].v, packedmask26.v); out[6].v = _mm_and_si128(out[6].v, packedmask26.v); out[3].v = _mm_add_epi64(out[3].v, c1); out[7].v = _mm_add_epi64(out[7].v, c2);
	c1 = _mm_srli_epi64(out[3].v, 25); c2 = _mm_srli_epi64(out[7].v, 25); out[3].v = _mm_and_si128(out[3].v, packedmask25.v); out[7].v = _mm_and_si128(out[7].v, packedmask25.v); out[4].v = _mm_add_epi64(out[4].v, c1); out[8].v = _mm_add_epi64(out[8].v, c2);
	                                   c2 = _mm_srli_epi64(out[8].v, 26);                                                     out[8].v = _mm_and_si128(out[8].v, packedmask26.v);                                         out[9].v = _mm_add_epi64(out[9].v, c2);
	                                   c2 = _mm_srli_epi64(out[9].v, 25);                                                     out[9].v = _mm_and_si128(out[9].v, packedmask25.v);                                         out[0].v = _mm_add_epi64(out[0].v, _mm_mul_epu32(c2, packednineteen.v));
	c1 = _mm_srli_epi64(out[0].v, 26); c2 = _mm_srli_epi64(out[4].v, 26); out[0].v = _mm_and_si128(out[0].v, packedmask26.v); out[4].v = _mm_and_si128(out[4].v, packedmask26.v); out[1].v = _mm_add_epi64(out[1].v, c1); out[5].v = _mm_add_epi64(out[5].v, c2);
}


/* Take a little-endian, 32-byte number and expand it into polynomial form */
static void
curve25519_expand(bignum25519 out, const unsigned char in[32]) {
	uint32_t x0,x1,x2,x3,x4,x5,x6,x7;

	x0 = *(uint32_t *)(in + 0);
	x1 = *(uint32_t *)(in + 4);
	x2 = *(uint32_t *)(in + 8);
	x3 = *(uint32_t *)(in + 12);
	x4 = *(uint32_t *)(in + 16);
	x5 = *(uint32_t *)(in + 20);
	x6 = *(uint32_t *)(in + 24);
	x7 = *(uint32_t *)(in + 28);

	out[0] = (                        x0       ) & 0x3ffffff;
	out[1] = ((((uint64_t)x1 << 32) | x0) >> 26) & 0x1ffffff;
	out[2] = ((((uint64_t)x2 << 32) | x1) >> 19) & 0x3ffffff;
	out[3] = ((((uint64_t)x3 << 32) | x2) >> 13) & 0x1ffffff;
	out[4] = ((                       x3) >>  6) & 0x3ffffff;
	out[5] = (                        x4       ) & 0x1ffffff;
	out[6] = ((((uint64_t)x5 << 32) | x4) >> 25) & 0x3ffffff;
	out[7] = ((((uint64_t)x6 << 32) | x5) >> 19) & 0x1ffffff;
	out[8] = ((((uint64_t)x7 << 32) | x6) >> 12) & 0x3ffffff;
	out[9] = ((                       x7) >>  6) & 0x1ffffff;
	out[10] = 0;
	out[11] = 0;
}

/* Take a fully reduced polynomial form number and contract it into a
 * little-endian, 32-byte array
 */
static void
curve25519_contract(unsigned char out[32], const bignum25519 in) {
	bignum25519 ALIGN(16) f;
	curve25519_copy(f, in);

	#define carry_pass() \
		f[1] += f[0] >> 26; f[0] &= 0x3ffffff; \
		f[2] += f[1] >> 25; f[1] &= 0x1ffffff; \
		f[3] += f[2] >> 26; f[2] &= 0x3ffffff; \
		f[4] += f[3] >> 25; f[3] &= 0x1ffffff; \
		f[5] += f[4] >> 26; f[4] &= 0x3ffffff; \
		f[6] += f[5] >> 25; f[5] &= 0x1ffffff; \
		f[7] += f[6] >> 26; f[6] &= 0x3ffffff; \
		f[8] += f[7] >> 25; f[7] &= 0x1ffffff; \
		f[9] += f[8] >> 26; f[8] &= 0x3ffffff;

	#define carry_pass_full() \
		carry_pass() \
		f[0] += 19 * (f[9] >> 25); f[9] &= 0x1ffffff;

	#define carry_pass_final() \
		carry_pass() \
		f[9] &= 0x1ffffff;

	carry_pass_full()
	carry_pass_full()

	/* now t is between 0 and 2^255-1, properly carried. */
	/* case 1: between 0 and 2^255-20. case 2: between 2^255-19 and 2^255-1. */
	f[0] += 19;
	carry_pass_full()

	/* now between 19 and 2^255-1 in both cases, and offset by 19. */
	f[0] += (1 << 26) - 19;
	f[1] += (1 << 25) - 1;
	f[2] += (1 << 26) - 1;
	f[3] += (1 << 25) - 1;
	f[4] += (1 << 26) - 1;
	f[5] += (1 << 25) - 1;
	f[6] += (1 << 26) - 1;
	f[7] += (1 << 25) - 1;
	f[8] += (1 << 26) - 1;
	f[9] += (1 << 25) - 1;

	/* now between 2^255 and 2^256-20, and offset by 2^255. */
	carry_pass_final()

	#undef carry_pass
	#undef carry_full
	#undef carry_final

	f[1] <<= 2;
	f[2] <<= 3;
	f[3] <<= 5;
	f[4] <<= 6;
	f[6] <<= 1;
	f[7] <<= 3;
	f[8] <<= 4;
	f[9] <<= 6;

	#define F(i, s) \
		out[s+0] |= (unsigned char )(f[i] & 0xff); \
		out[s+1] = (unsigned char )((f[i] >> 8) & 0xff); \
		out[s+2] = (unsigned char )((f[i] >> 16) & 0xff); \
		out[s+3] = (unsigned char )((f[i] >> 24) & 0xff);

	out[0] = 0;
	out[16] = 0;
	F(0,0);
	F(1,3);
	F(2,6);
	F(3,9);
	F(4,12);
	F(5,16);
	F(6,19);
	F(7,22);
	F(8,25);
	F(9,28);
	#undef F
}

/* if (iswap) swap(a, b) */
DONNA_INLINE static void
curve25519_swap_conditional(bignum25519 a, bignum25519 b, uint32_t iswap) {
	const uint32_t swap = (uint32_t)(-(int32_t)iswap);
	xmmi a0,a1,a2,b0,b1,b2,x0,x1,x2;
	xmmi mask = _mm_cvtsi32_si128(swap);
	mask = _mm_shuffle_epi32(mask, 0);
	a0 = _mm_load_si128((xmmi *)a + 0);
	a1 = _mm_load_si128((xmmi *)a + 1);
	b0 = _mm_load_si128((xmmi *)b + 0);
	b1 = _mm_load_si128((xmmi *)b + 1);
	b0 = _mm_xor_si128(a0, b0);
	b1 = _mm_xor_si128(a1, b1);
	x0 = _mm_and_si128(b0, mask);
	x1 = _mm_and_si128(b1, mask);
	x0 = _mm_xor_si128(x0, a0);
	x1 = _mm_xor_si128(x1, a1);
	a0 = _mm_xor_si128(x0, b0);
	a1 = _mm_xor_si128(x1, b1);
	_mm_store_si128((xmmi *)a + 0, x0);
	_mm_store_si128((xmmi *)a + 1, x1);	
	_mm_store_si128((xmmi *)b + 0, a0);
	_mm_store_si128((xmmi *)b + 1, a1);

	a2 = _mm_load_si128((xmmi *)a + 2);
	b2 = _mm_load_si128((xmmi *)b + 2);
	b2 = _mm_xor_si128(a2, b2);
	x2 = _mm_and_si128(b2, mask);
	x2 = _mm_xor_si128(x2, a2);
	a2 = _mm_xor_si128(x2, b2);	
	_mm_store_si128((xmmi *)b + 2, a2);
	_mm_store_si128((xmmi *)a + 2, x2);
}

/* out = (flag) ? out : in */
DONNA_INLINE static void
curve25519_move_conditional_bytes(uint8_t out[96], const uint8_t in[96], uint32_t flag) {
	xmmi a0,a1,a2,a3,a4,a5,b0,b1,b2,b3,b4,b5;
	const uint32_t nb = flag - 1;
	xmmi masknb = _mm_shuffle_epi32(_mm_cvtsi32_si128(nb),0);
	a0 = _mm_load_si128((xmmi *)in + 0);
	a1 = _mm_load_si128((xmmi *)in + 1);
	a2 = _mm_load_si128((xmmi *)in + 2);
	b0 = _mm_load_si128((xmmi *)out + 0);
	b1 = _mm_load_si128((xmmi *)out + 1);
	b2 = _mm_load_si128((xmmi *)out + 2);
	a0 = _mm_andnot_si128(masknb, a0);
	a1 = _mm_andnot_si128(masknb, a1);
	a2 = _mm_andnot_si128(masknb, a2);
	b0 = _mm_and_si128(masknb, b0);
	b1 = _mm_and_si128(masknb, b1);
	b2 = _mm_and_si128(masknb, b2);
	a0 = _mm_or_si128(a0, b0);
	a1 = _mm_or_si128(a1, b1);
	a2 = _mm_or_si128(a2, b2);
	_mm_store_si128((xmmi*)out + 0, a0);
	_mm_store_si128((xmmi*)out + 1, a1);
	_mm_store_si128((xmmi*)out + 2, a2);

	a3 = _mm_load_si128((xmmi *)in + 3);
	a4 = _mm_load_si128((xmmi *)in + 4);
	a5 = _mm_load_si128((xmmi *)in + 5);
	b3 = _mm_load_si128((xmmi *)out + 3);
	b4 = _mm_load_si128((xmmi *)out + 4);
	b5 = _mm_load_si128((xmmi *)out + 5);
	a3 = _mm_andnot_si128(masknb, a3);
	a4 = _mm_andnot_si128(masknb, a4);
	a5 = _mm_andnot_si128(masknb, a5);
	b3 = _mm_and_si128(masknb, b3);
	b4 = _mm_and_si128(masknb, b4);
	b5 = _mm_and_si128(masknb, b5);
	a3 = _mm_or_si128(a3, b3);
	a4 = _mm_or_si128(a4, b4);
	a5 = _mm_or_si128(a5, b5);
	_mm_store_si128((xmmi*)out + 3, a3);
	_mm_store_si128((xmmi*)out + 4, a4);
	_mm_store_si128((xmmi*)out + 5, a5);
}

