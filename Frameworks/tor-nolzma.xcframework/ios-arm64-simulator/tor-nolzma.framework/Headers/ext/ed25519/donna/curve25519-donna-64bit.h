/*
	Public domain by Adam Langley <agl@imperialviolet.org> &
	                 Andrew M. <liquidsun@gmail.com>
	See: https://github.com/floodyberry/curve25519-donna

	64bit integer curve25519 implementation
*/

typedef uint64_t bignum25519[5];

//static const uint64_t reduce_mask_40 = ((uint64_t)1 << 40) - 1;
static const uint64_t reduce_mask_51 = ((uint64_t)1 << 51) - 1;
//static const uint64_t reduce_mask_56 = ((uint64_t)1 << 56) - 1;

/* out = in */
DONNA_INLINE static void
curve25519_copy(bignum25519 out, const bignum25519 in) {
	out[0] = in[0];
	out[1] = in[1];
	out[2] = in[2];
	out[3] = in[3];
	out[4] = in[4];
}

/* out = a + b */
DONNA_INLINE static void
curve25519_add(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	out[0] = a[0] + b[0];
	out[1] = a[1] + b[1];
	out[2] = a[2] + b[2];
	out[3] = a[3] + b[3];
	out[4] = a[4] + b[4];
}

/* out = a + b, where a and/or b are the result of a basic op (add,sub) */
DONNA_INLINE static void
curve25519_add_after_basic(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	out[0] = a[0] + b[0];
	out[1] = a[1] + b[1];
	out[2] = a[2] + b[2];
	out[3] = a[3] + b[3];
	out[4] = a[4] + b[4];
}

DONNA_INLINE static void
curve25519_add_reduce(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	uint64_t c;
	out[0] = a[0] + b[0]    ; c = (out[0] >> 51); out[0] &= reduce_mask_51;
	out[1] = a[1] + b[1] + c; c = (out[1] >> 51); out[1] &= reduce_mask_51;
	out[2] = a[2] + b[2] + c; c = (out[2] >> 51); out[2] &= reduce_mask_51;
	out[3] = a[3] + b[3] + c; c = (out[3] >> 51); out[3] &= reduce_mask_51;
	out[4] = a[4] + b[4] + c; c = (out[4] >> 51); out[4] &= reduce_mask_51;
	out[0] += c * 19;
}

/* multiples of p */
static const uint64_t twoP0      = 0x0fffffffffffda;
static const uint64_t twoP1234   = 0x0ffffffffffffe;
static const uint64_t fourP0     = 0x1fffffffffffb4;
static const uint64_t fourP1234  = 0x1ffffffffffffc;

/* out = a - b */
DONNA_INLINE static void
curve25519_sub(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	out[0] = a[0] + twoP0    - b[0];
	out[1] = a[1] + twoP1234 - b[1];
	out[2] = a[2] + twoP1234 - b[2];
	out[3] = a[3] + twoP1234 - b[3];
	out[4] = a[4] + twoP1234 - b[4];
}

/* out = a - b, where a and/or b are the result of a basic op (add,sub) */
DONNA_INLINE static void
curve25519_sub_after_basic(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	out[0] = a[0] + fourP0    - b[0];
	out[1] = a[1] + fourP1234 - b[1];
	out[2] = a[2] + fourP1234 - b[2];
	out[3] = a[3] + fourP1234 - b[3];
	out[4] = a[4] + fourP1234 - b[4];
}

DONNA_INLINE static void
curve25519_sub_reduce(bignum25519 out, const bignum25519 a, const bignum25519 b) {
	uint64_t c;
	out[0] = a[0] + fourP0    - b[0]    ; c = (out[0] >> 51); out[0] &= reduce_mask_51;
	out[1] = a[1] + fourP1234 - b[1] + c; c = (out[1] >> 51); out[1] &= reduce_mask_51;
	out[2] = a[2] + fourP1234 - b[2] + c; c = (out[2] >> 51); out[2] &= reduce_mask_51;
	out[3] = a[3] + fourP1234 - b[3] + c; c = (out[3] >> 51); out[3] &= reduce_mask_51;
	out[4] = a[4] + fourP1234 - b[4] + c; c = (out[4] >> 51); out[4] &= reduce_mask_51;
	out[0] += c * 19;
}

/* out = -a */
DONNA_INLINE static void
curve25519_neg(bignum25519 out, const bignum25519 a) {
	uint64_t c;
	out[0] = twoP0    - a[0]    ; c = (out[0] >> 51); out[0] &= reduce_mask_51;
	out[1] = twoP1234 - a[1] + c; c = (out[1] >> 51); out[1] &= reduce_mask_51;
	out[2] = twoP1234 - a[2] + c; c = (out[2] >> 51); out[2] &= reduce_mask_51;
	out[3] = twoP1234 - a[3] + c; c = (out[3] >> 51); out[3] &= reduce_mask_51;
	out[4] = twoP1234 - a[4] + c; c = (out[4] >> 51); out[4] &= reduce_mask_51;
	out[0] += c * 19;
}

/* out = a * b */
DONNA_INLINE static void
curve25519_mul(bignum25519 out, const bignum25519 in2, const bignum25519 in) {
#if !defined(HAVE_NATIVE_UINT128)
	uint128_t mul;
#endif
	uint128_t t[5];
	uint64_t r0,r1,r2,r3,r4,s0,s1,s2,s3,s4,c;

	r0 = in[0];
	r1 = in[1];
	r2 = in[2];
	r3 = in[3];
	r4 = in[4];

	s0 = in2[0];
	s1 = in2[1];
	s2 = in2[2];
	s3 = in2[3];
	s4 = in2[4];

#if defined(HAVE_NATIVE_UINT128)
	t[0]  =  ((uint128_t) r0) * s0;
	t[1]  =  ((uint128_t) r0) * s1 + ((uint128_t) r1) * s0;
	t[2]  =  ((uint128_t) r0) * s2 + ((uint128_t) r2) * s0 + ((uint128_t) r1) * s1;
	t[3]  =  ((uint128_t) r0) * s3 + ((uint128_t) r3) * s0 + ((uint128_t) r1) * s2 + ((uint128_t) r2) * s1;
	t[4]  =  ((uint128_t) r0) * s4 + ((uint128_t) r4) * s0 + ((uint128_t) r3) * s1 + ((uint128_t) r1) * s3 + ((uint128_t) r2) * s2;
#else
	mul64x64_128(t[0], r0, s0)
	mul64x64_128(t[1], r0, s1) mul64x64_128(mul, r1, s0) add128(t[1], mul)
	mul64x64_128(t[2], r0, s2) mul64x64_128(mul, r2, s0) add128(t[2], mul) mul64x64_128(mul, r1, s1) add128(t[2], mul)
	mul64x64_128(t[3], r0, s3) mul64x64_128(mul, r3, s0) add128(t[3], mul) mul64x64_128(mul, r1, s2) add128(t[3], mul) mul64x64_128(mul, r2, s1) add128(t[3], mul)
	mul64x64_128(t[4], r0, s4) mul64x64_128(mul, r4, s0) add128(t[4], mul) mul64x64_128(mul, r3, s1) add128(t[4], mul) mul64x64_128(mul, r1, s3) add128(t[4], mul) mul64x64_128(mul, r2, s2) add128(t[4], mul)
#endif

	r1 *= 19;
	r2 *= 19;
	r3 *= 19;
	r4 *= 19;

#if defined(HAVE_NATIVE_UINT128)
	t[0] += ((uint128_t) r4) * s1 + ((uint128_t) r1) * s4 + ((uint128_t) r2) * s3 + ((uint128_t) r3) * s2;
	t[1] += ((uint128_t) r4) * s2 + ((uint128_t) r2) * s4 + ((uint128_t) r3) * s3;
	t[2] += ((uint128_t) r4) * s3 + ((uint128_t) r3) * s4;
	t[3] += ((uint128_t) r4) * s4;
#else
	mul64x64_128(mul, r4, s1) add128(t[0], mul) mul64x64_128(mul, r1, s4) add128(t[0], mul) mul64x64_128(mul, r2, s3) add128(t[0], mul) mul64x64_128(mul, r3, s2) add128(t[0], mul)
	mul64x64_128(mul, r4, s2) add128(t[1], mul) mul64x64_128(mul, r2, s4) add128(t[1], mul) mul64x64_128(mul, r3, s3) add128(t[1], mul)
	mul64x64_128(mul, r4, s3) add128(t[2], mul) mul64x64_128(mul, r3, s4) add128(t[2], mul)
	mul64x64_128(mul, r4, s4) add128(t[3], mul)
#endif


	                     r0 = lo128(t[0]) & reduce_mask_51; shr128(c, t[0], 51);
	add128_64(t[1], c)   r1 = lo128(t[1]) & reduce_mask_51; shr128(c, t[1], 51);
	add128_64(t[2], c)   r2 = lo128(t[2]) & reduce_mask_51; shr128(c, t[2], 51);
	add128_64(t[3], c)   r3 = lo128(t[3]) & reduce_mask_51; shr128(c, t[3], 51);
	add128_64(t[4], c)   r4 = lo128(t[4]) & reduce_mask_51; shr128(c, t[4], 51);
	r0 +=   c * 19; c = r0 >> 51; r0 = r0 & reduce_mask_51;
	r1 +=   c;

	out[0] = r0;
	out[1] = r1;
	out[2] = r2;
	out[3] = r3;
	out[4] = r4;
}

DONNA_NOINLINE static void
curve25519_mul_noinline(bignum25519 out, const bignum25519 in2, const bignum25519 in) {
	curve25519_mul(out, in2, in);
}

/* out = in^(2 * count) */
DONNA_NOINLINE static void
curve25519_square_times(bignum25519 out, const bignum25519 in, uint64_t count) {
#if !defined(HAVE_NATIVE_UINT128)
	uint128_t mul;
#endif
	uint128_t t[5];
	uint64_t r0,r1,r2,r3,r4,c;
	uint64_t d0,d1,d2,d4,d419;

	r0 = in[0];
	r1 = in[1];
	r2 = in[2];
	r3 = in[3];
	r4 = in[4];

	do {
		d0 = r0 * 2;
		d1 = r1 * 2;
		d2 = r2 * 2 * 19;
		d419 = r4 * 19;
		d4 = d419 * 2;

#if defined(HAVE_NATIVE_UINT128)
		t[0] = ((uint128_t) r0) * r0 + ((uint128_t) d4) * r1 + (((uint128_t) d2) * (r3     ));
		t[1] = ((uint128_t) d0) * r1 + ((uint128_t) d4) * r2 + (((uint128_t) r3) * (r3 * 19));
		t[2] = ((uint128_t) d0) * r2 + ((uint128_t) r1) * r1 + (((uint128_t) d4) * (r3     ));
		t[3] = ((uint128_t) d0) * r3 + ((uint128_t) d1) * r2 + (((uint128_t) r4) * (d419   ));
		t[4] = ((uint128_t) d0) * r4 + ((uint128_t) d1) * r3 + (((uint128_t) r2) * (r2     ));
#else
		mul64x64_128(t[0], r0, r0) mul64x64_128(mul, d4, r1) add128(t[0], mul) mul64x64_128(mul, d2,      r3) add128(t[0], mul)
		mul64x64_128(t[1], d0, r1) mul64x64_128(mul, d4, r2) add128(t[1], mul) mul64x64_128(mul, r3, r3 * 19) add128(t[1], mul)
		mul64x64_128(t[2], d0, r2) mul64x64_128(mul, r1, r1) add128(t[2], mul) mul64x64_128(mul, d4,      r3) add128(t[2], mul)
		mul64x64_128(t[3], d0, r3) mul64x64_128(mul, d1, r2) add128(t[3], mul) mul64x64_128(mul, r4,    d419) add128(t[3], mul)
		mul64x64_128(t[4], d0, r4) mul64x64_128(mul, d1, r3) add128(t[4], mul) mul64x64_128(mul, r2,      r2) add128(t[4], mul)
#endif

		r0 = lo128(t[0]) & reduce_mask_51;
		r1 = lo128(t[1]) & reduce_mask_51; shl128(c, t[0], 13); r1 += c;
		r2 = lo128(t[2]) & reduce_mask_51; shl128(c, t[1], 13); r2 += c;
		r3 = lo128(t[3]) & reduce_mask_51; shl128(c, t[2], 13); r3 += c;
		r4 = lo128(t[4]) & reduce_mask_51; shl128(c, t[3], 13); r4 += c; 
		                                   shl128(c, t[4], 13); r0 += c * 19;
		               c = r0 >> 51; r0 &= reduce_mask_51;
		r1 += c     ;  c = r1 >> 51; r1 &= reduce_mask_51;
		r2 += c     ;  c = r2 >> 51; r2 &= reduce_mask_51;
		r3 += c     ;  c = r3 >> 51; r3 &= reduce_mask_51;
		r4 += c     ;  c = r4 >> 51; r4 &= reduce_mask_51;
		r0 += c * 19;
	} while(--count);

	out[0] = r0;
	out[1] = r1;
	out[2] = r2;
	out[3] = r3;
	out[4] = r4;
}

DONNA_INLINE static void
curve25519_square(bignum25519 out, const bignum25519 in) {
#if !defined(HAVE_NATIVE_UINT128)
	uint128_t mul;
#endif
	uint128_t t[5];
	uint64_t r0,r1,r2,r3,r4,c;
	uint64_t d0,d1,d2,d4,d419;

	r0 = in[0];
	r1 = in[1];
	r2 = in[2];
	r3 = in[3];
	r4 = in[4];

	d0 = r0 * 2;
	d1 = r1 * 2;
	d2 = r2 * 2 * 19;
	d419 = r4 * 19;
	d4 = d419 * 2;

#if defined(HAVE_NATIVE_UINT128)
	t[0] = ((uint128_t) r0) * r0 + ((uint128_t) d4) * r1 + (((uint128_t) d2) * (r3     ));
	t[1] = ((uint128_t) d0) * r1 + ((uint128_t) d4) * r2 + (((uint128_t) r3) * (r3 * 19));
	t[2] = ((uint128_t) d0) * r2 + ((uint128_t) r1) * r1 + (((uint128_t) d4) * (r3     ));
	t[3] = ((uint128_t) d0) * r3 + ((uint128_t) d1) * r2 + (((uint128_t) r4) * (d419   ));
	t[4] = ((uint128_t) d0) * r4 + ((uint128_t) d1) * r3 + (((uint128_t) r2) * (r2     ));
#else
	mul64x64_128(t[0], r0, r0) mul64x64_128(mul, d4, r1) add128(t[0], mul) mul64x64_128(mul, d2,      r3) add128(t[0], mul)
	mul64x64_128(t[1], d0, r1) mul64x64_128(mul, d4, r2) add128(t[1], mul) mul64x64_128(mul, r3, r3 * 19) add128(t[1], mul)
	mul64x64_128(t[2], d0, r2) mul64x64_128(mul, r1, r1) add128(t[2], mul) mul64x64_128(mul, d4,      r3) add128(t[2], mul)
	mul64x64_128(t[3], d0, r3) mul64x64_128(mul, d1, r2) add128(t[3], mul) mul64x64_128(mul, r4,    d419) add128(t[3], mul)
	mul64x64_128(t[4], d0, r4) mul64x64_128(mul, d1, r3) add128(t[4], mul) mul64x64_128(mul, r2,      r2) add128(t[4], mul)
#endif

	                     r0 = lo128(t[0]) & reduce_mask_51; shr128(c, t[0], 51);
	add128_64(t[1], c)   r1 = lo128(t[1]) & reduce_mask_51; shr128(c, t[1], 51);
	add128_64(t[2], c)   r2 = lo128(t[2]) & reduce_mask_51; shr128(c, t[2], 51);
	add128_64(t[3], c)   r3 = lo128(t[3]) & reduce_mask_51; shr128(c, t[3], 51);
	add128_64(t[4], c)   r4 = lo128(t[4]) & reduce_mask_51; shr128(c, t[4], 51);
	r0 +=   c * 19; c = r0 >> 51; r0 = r0 & reduce_mask_51;
	r1 +=   c;

	out[0] = r0;
	out[1] = r1;
	out[2] = r2;
	out[3] = r3;
	out[4] = r4;
}

/* Take a little-endian, 32-byte number and expand it into polynomial form */
DONNA_INLINE static void
curve25519_expand(bignum25519 out, const unsigned char *in) {
	static const union { uint8_t b[2]; uint16_t s; } endian_check = {{1,0}};
	uint64_t x0,x1,x2,x3;

	if (endian_check.s == 1) {
		x0 = *(uint64_t *)(in + 0);
		x1 = *(uint64_t *)(in + 8);
		x2 = *(uint64_t *)(in + 16);
		x3 = *(uint64_t *)(in + 24);
	} else {
		#define F(s)                         \
			((((uint64_t)in[s + 0])      ) | \
			 (((uint64_t)in[s + 1]) <<  8) | \
			 (((uint64_t)in[s + 2]) << 16) | \
			 (((uint64_t)in[s + 3]) << 24) | \
			 (((uint64_t)in[s + 4]) << 32) | \
			 (((uint64_t)in[s + 5]) << 40) | \
			 (((uint64_t)in[s + 6]) << 48) | \
			 (((uint64_t)in[s + 7]) << 56))

		x0 = F(0);
		x1 = F(8);
		x2 = F(16);
		x3 = F(24);
	}

	out[0] = x0 & reduce_mask_51; x0 = (x0 >> 51) | (x1 << 13);
	out[1] = x0 & reduce_mask_51; x1 = (x1 >> 38) | (x2 << 26);
	out[2] = x1 & reduce_mask_51; x2 = (x2 >> 25) | (x3 << 39);
	out[3] = x2 & reduce_mask_51; x3 = (x3 >> 12);
	out[4] = x3 & reduce_mask_51;
}

/* Take a fully reduced polynomial form number and contract it into a
 * little-endian, 32-byte array
 */
DONNA_INLINE static void
curve25519_contract(unsigned char *out, const bignum25519 input) {
	uint64_t t[5];
	uint64_t f, i;

	t[0] = input[0];
	t[1] = input[1];
	t[2] = input[2];
	t[3] = input[3];
	t[4] = input[4];

	#define curve25519_contract_carry() \
		t[1] += t[0] >> 51; t[0] &= reduce_mask_51; \
		t[2] += t[1] >> 51; t[1] &= reduce_mask_51; \
		t[3] += t[2] >> 51; t[2] &= reduce_mask_51; \
		t[4] += t[3] >> 51; t[3] &= reduce_mask_51;

	#define curve25519_contract_carry_full() curve25519_contract_carry() \
		t[0] += 19 * (t[4] >> 51); t[4] &= reduce_mask_51;

	#define curve25519_contract_carry_final() curve25519_contract_carry() \
		t[4] &= reduce_mask_51;

	curve25519_contract_carry_full()
	curve25519_contract_carry_full()

	/* now t is between 0 and 2^255-1, properly carried. */
	/* case 1: between 0 and 2^255-20. case 2: between 2^255-19 and 2^255-1. */
	t[0] += 19;
	curve25519_contract_carry_full()

	/* now between 19 and 2^255-1 in both cases, and offset by 19. */
	t[0] += (reduce_mask_51 + 1) - 19;
	t[1] += (reduce_mask_51 + 1) - 1;
	t[2] += (reduce_mask_51 + 1) - 1;
	t[3] += (reduce_mask_51 + 1) - 1;
	t[4] += (reduce_mask_51 + 1) - 1;

	/* now between 2^255 and 2^256-20, and offset by 2^255. */
	curve25519_contract_carry_final()

	#define write51full(n,shift) \
		f = ((t[n] >> shift) | (t[n+1] << (51 - shift))); \
		for (i = 0; i < 8; i++, f >>= 8) *out++ = (unsigned char)f;
	#define write51(n) write51full(n,13*n)
	write51(0)
	write51(1)
	write51(2)
	write51(3)
}

#if !defined(ED25519_GCC_64BIT_CHOOSE)

/* out = (flag) ? in : out */
DONNA_INLINE static void
curve25519_move_conditional_bytes(uint8_t out[96], const uint8_t in[96], uint64_t flag) {
	const uint64_t nb = flag - 1, b = ~nb;
	const uint64_t *inq = (const uint64_t *)in;
	uint64_t *outq = (uint64_t *)out;
	outq[0] = (outq[0] & nb) | (inq[0] & b);
	outq[1] = (outq[1] & nb) | (inq[1] & b);
	outq[2] = (outq[2] & nb) | (inq[2] & b);
	outq[3] = (outq[3] & nb) | (inq[3] & b);
	outq[4] = (outq[4] & nb) | (inq[4] & b);
	outq[5] = (outq[5] & nb) | (inq[5] & b);
	outq[6] = (outq[6] & nb) | (inq[6] & b);
	outq[7] = (outq[7] & nb) | (inq[7] & b);
	outq[8] = (outq[8] & nb) | (inq[8] & b);
	outq[9] = (outq[9] & nb) | (inq[9] & b);
	outq[10] = (outq[10] & nb) | (inq[10] & b);
	outq[11] = (outq[11] & nb) | (inq[11] & b);
}

/* if (iswap) swap(a, b) */
DONNA_INLINE static void
curve25519_swap_conditional(bignum25519 a, bignum25519 b, uint64_t iswap) {
	const uint64_t swap = (uint64_t)(-(int64_t)iswap);
	uint64_t x0,x1,x2,x3,x4;

	x0 = swap & (a[0] ^ b[0]); a[0] ^= x0; b[0] ^= x0;
	x1 = swap & (a[1] ^ b[1]); a[1] ^= x1; b[1] ^= x1;
	x2 = swap & (a[2] ^ b[2]); a[2] ^= x2; b[2] ^= x2;
	x3 = swap & (a[3] ^ b[3]); a[3] ^= x3; b[3] ^= x3;
	x4 = swap & (a[4] ^ b[4]); a[4] ^= x4; b[4] ^= x4;
}

#endif /* ED25519_GCC_64BIT_CHOOSE */

#define ED25519_64BIT_TABLES

