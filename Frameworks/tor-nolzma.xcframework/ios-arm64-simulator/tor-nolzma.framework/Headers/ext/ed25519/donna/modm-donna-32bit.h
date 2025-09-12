/*
	Public domain by Andrew M. <liquidsun@gmail.com>
*/


/*
	Arithmetic modulo the group order n = 2^252 +  27742317777372353535851937790883648493 = 7237005577332262213973186563042994240857116359379907606001950938285454250989

	k = 32
	b = 1 << 8 = 256
	m = 2^252 + 27742317777372353535851937790883648493 = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed
	mu = floor( b^(k*2) / m ) = 0xfffffffffffffffffffffffffffffffeb2106215d086329a7ed9ce5a30a2c131b
*/

#define bignum256modm_bits_per_limb 30
#define bignum256modm_limb_size 9

typedef uint32_t bignum256modm_element_t;
typedef bignum256modm_element_t bignum256modm[9];

static const bignum256modm modm_m = {
	0x1cf5d3ed, 0x20498c69, 0x2f79cd65, 0x37be77a8,
	0x00000014,	0x00000000, 0x00000000,	0x00000000,
	0x00001000
};

static const bignum256modm modm_mu = {
	0x0a2c131b, 0x3673968c, 0x06329a7e, 0x01885742,
	0x3fffeb21, 0x3fffffff, 0x3fffffff, 0x3fffffff,
	0x000fffff
};

static bignum256modm_element_t
lt_modm(bignum256modm_element_t a, bignum256modm_element_t b) {
	return (a - b) >> 31;
}

/* see HAC, Alg. 14.42 Step 4 */
static void
reduce256_modm(bignum256modm r) {
	bignum256modm t;
	bignum256modm_element_t b = 0, pb, mask;

	/* t = r - m */
	pb = 0;
	pb += modm_m[0]; b = lt_modm(r[0], pb); t[0] = (r[0] - pb + (b << 30)); pb = b;
	pb += modm_m[1]; b = lt_modm(r[1], pb); t[1] = (r[1] - pb + (b << 30)); pb = b;
	pb += modm_m[2]; b = lt_modm(r[2], pb); t[2] = (r[2] - pb + (b << 30)); pb = b;
	pb += modm_m[3]; b = lt_modm(r[3], pb); t[3] = (r[3] - pb + (b << 30)); pb = b;
	pb += modm_m[4]; b = lt_modm(r[4], pb); t[4] = (r[4] - pb + (b << 30)); pb = b;
	pb += modm_m[5]; b = lt_modm(r[5], pb); t[5] = (r[5] - pb + (b << 30)); pb = b;
	pb += modm_m[6]; b = lt_modm(r[6], pb); t[6] = (r[6] - pb + (b << 30)); pb = b;
	pb += modm_m[7]; b = lt_modm(r[7], pb); t[7] = (r[7] - pb + (b << 30)); pb = b;
	pb += modm_m[8]; b = lt_modm(r[8], pb); t[8] = (r[8] - pb + (b << 16));

	/* keep r if r was smaller than m */
	mask = b - 1;
	r[0] ^= mask & (r[0] ^ t[0]);
	r[1] ^= mask & (r[1] ^ t[1]);
	r[2] ^= mask & (r[2] ^ t[2]);
	r[3] ^= mask & (r[3] ^ t[3]);
	r[4] ^= mask & (r[4] ^ t[4]);
	r[5] ^= mask & (r[5] ^ t[5]);
	r[6] ^= mask & (r[6] ^ t[6]);
	r[7] ^= mask & (r[7] ^ t[7]);
	r[8] ^= mask & (r[8] ^ t[8]);
}

/*
	Barrett reduction,  see HAC, Alg. 14.42

	Instead of passing in x, pre-process in to q1 and r1 for efficiency
*/
static void
barrett_reduce256_modm(bignum256modm r, const bignum256modm q1, const bignum256modm r1) {
	bignum256modm q3, r2;
	uint64_t c;
	bignum256modm_element_t f, b, pb;

	/* q1 = x >> 248 = 264 bits = 9 30 bit elements
	   q2 = mu * q1
	   q3 = (q2 / 256(32+1)) = q2 / (2^8)^(32+1) = q2 >> 264 */
	c  = mul32x32_64(modm_mu[0], q1[7]) + mul32x32_64(modm_mu[1], q1[6]) + mul32x32_64(modm_mu[2], q1[5]) + mul32x32_64(modm_mu[3], q1[4]) + mul32x32_64(modm_mu[4], q1[3]) + mul32x32_64(modm_mu[5], q1[2]) + mul32x32_64(modm_mu[6], q1[1]) + mul32x32_64(modm_mu[7], q1[0]); 
	c >>= 30;
	c += mul32x32_64(modm_mu[0], q1[8]) + mul32x32_64(modm_mu[1], q1[7]) + mul32x32_64(modm_mu[2], q1[6]) + mul32x32_64(modm_mu[3], q1[5]) + mul32x32_64(modm_mu[4], q1[4]) + mul32x32_64(modm_mu[5], q1[3]) + mul32x32_64(modm_mu[6], q1[2]) + mul32x32_64(modm_mu[7], q1[1]) + mul32x32_64(modm_mu[8], q1[0]);
	f = (bignum256modm_element_t)c; q3[0] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[1], q1[8]) + mul32x32_64(modm_mu[2], q1[7]) + mul32x32_64(modm_mu[3], q1[6]) + mul32x32_64(modm_mu[4], q1[5]) + mul32x32_64(modm_mu[5], q1[4]) + mul32x32_64(modm_mu[6], q1[3]) + mul32x32_64(modm_mu[7], q1[2]) + mul32x32_64(modm_mu[8], q1[1]);
	f = (bignum256modm_element_t)c; q3[0] |= (f << 6) & 0x3fffffff; q3[1] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[2], q1[8]) + mul32x32_64(modm_mu[3], q1[7]) + mul32x32_64(modm_mu[4], q1[6]) + mul32x32_64(modm_mu[5], q1[5]) + mul32x32_64(modm_mu[6], q1[4]) + mul32x32_64(modm_mu[7], q1[3]) + mul32x32_64(modm_mu[8], q1[2]);
	f = (bignum256modm_element_t)c; q3[1] |= (f << 6) & 0x3fffffff; q3[2] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[3], q1[8]) + mul32x32_64(modm_mu[4], q1[7]) + mul32x32_64(modm_mu[5], q1[6]) + mul32x32_64(modm_mu[6], q1[5]) + mul32x32_64(modm_mu[7], q1[4]) + mul32x32_64(modm_mu[8], q1[3]);
	f = (bignum256modm_element_t)c; q3[2] |= (f << 6) & 0x3fffffff; q3[3] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[4], q1[8]) + mul32x32_64(modm_mu[5], q1[7]) + mul32x32_64(modm_mu[6], q1[6]) + mul32x32_64(modm_mu[7], q1[5]) + mul32x32_64(modm_mu[8], q1[4]);
	f = (bignum256modm_element_t)c; q3[3] |= (f << 6) & 0x3fffffff; q3[4] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[5], q1[8]) + mul32x32_64(modm_mu[6], q1[7]) + mul32x32_64(modm_mu[7], q1[6]) + mul32x32_64(modm_mu[8], q1[5]);
	f = (bignum256modm_element_t)c; q3[4] |= (f << 6) & 0x3fffffff; q3[5] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[6], q1[8]) + mul32x32_64(modm_mu[7], q1[7]) + mul32x32_64(modm_mu[8], q1[6]);
	f = (bignum256modm_element_t)c; q3[5] |= (f << 6) & 0x3fffffff; q3[6] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[7], q1[8]) + mul32x32_64(modm_mu[8], q1[7]);
	f = (bignum256modm_element_t)c; q3[6] |= (f << 6) & 0x3fffffff; q3[7] = (f >> 24) & 0x3f; c >>= 30;
	c += mul32x32_64(modm_mu[8], q1[8]);
	f = (bignum256modm_element_t)c; q3[7] |= (f << 6) & 0x3fffffff; q3[8] = (bignum256modm_element_t)(c >> 24);

	/* r1 = (x mod 256^(32+1)) = x mod (2^8)(31+1) = x & ((1 << 264) - 1)
	   r2 = (q3 * m) mod (256^(32+1)) = (q3 * m) & ((1 << 264) - 1) */
	c = mul32x32_64(modm_m[0], q3[0]);
	r2[0] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[1]) + mul32x32_64(modm_m[1], q3[0]);
	r2[1] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[2]) + mul32x32_64(modm_m[1], q3[1]) + mul32x32_64(modm_m[2], q3[0]);
	r2[2] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[3]) + mul32x32_64(modm_m[1], q3[2]) + mul32x32_64(modm_m[2], q3[1]) + mul32x32_64(modm_m[3], q3[0]);
	r2[3] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[4]) + mul32x32_64(modm_m[1], q3[3]) + mul32x32_64(modm_m[2], q3[2]) + mul32x32_64(modm_m[3], q3[1]) + mul32x32_64(modm_m[4], q3[0]);
	r2[4] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[5]) + mul32x32_64(modm_m[1], q3[4]) + mul32x32_64(modm_m[2], q3[3]) + mul32x32_64(modm_m[3], q3[2]) + mul32x32_64(modm_m[4], q3[1]) + mul32x32_64(modm_m[5], q3[0]);
	r2[5] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[6]) + mul32x32_64(modm_m[1], q3[5]) + mul32x32_64(modm_m[2], q3[4]) + mul32x32_64(modm_m[3], q3[3]) + mul32x32_64(modm_m[4], q3[2]) + mul32x32_64(modm_m[5], q3[1]) + mul32x32_64(modm_m[6], q3[0]);
	r2[6] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[7]) + mul32x32_64(modm_m[1], q3[6]) + mul32x32_64(modm_m[2], q3[5]) + mul32x32_64(modm_m[3], q3[4]) + mul32x32_64(modm_m[4], q3[3]) + mul32x32_64(modm_m[5], q3[2]) + mul32x32_64(modm_m[6], q3[1]) + mul32x32_64(modm_m[7], q3[0]);
	r2[7] = (bignum256modm_element_t)(c & 0x3fffffff); c >>= 30;
	c += mul32x32_64(modm_m[0], q3[8]) + mul32x32_64(modm_m[1], q3[7]) + mul32x32_64(modm_m[2], q3[6]) + mul32x32_64(modm_m[3], q3[5]) + mul32x32_64(modm_m[4], q3[4]) + mul32x32_64(modm_m[5], q3[3]) + mul32x32_64(modm_m[6], q3[2]) + mul32x32_64(modm_m[7], q3[1]) + mul32x32_64(modm_m[8], q3[0]);
	r2[8] = (bignum256modm_element_t)(c & 0xffffff);

	/* r = r1 - r2
	   if (r < 0) r += (1 << 264) */
	pb = 0;
	pb += r2[0]; b = lt_modm(r1[0], pb); r[0] = (r1[0] - pb + (b << 30)); pb = b;
	pb += r2[1]; b = lt_modm(r1[1], pb); r[1] = (r1[1] - pb + (b << 30)); pb = b;
	pb += r2[2]; b = lt_modm(r1[2], pb); r[2] = (r1[2] - pb + (b << 30)); pb = b;
	pb += r2[3]; b = lt_modm(r1[3], pb); r[3] = (r1[3] - pb + (b << 30)); pb = b;
	pb += r2[4]; b = lt_modm(r1[4], pb); r[4] = (r1[4] - pb + (b << 30)); pb = b;
	pb += r2[5]; b = lt_modm(r1[5], pb); r[5] = (r1[5] - pb + (b << 30)); pb = b;
	pb += r2[6]; b = lt_modm(r1[6], pb); r[6] = (r1[6] - pb + (b << 30)); pb = b;
	pb += r2[7]; b = lt_modm(r1[7], pb); r[7] = (r1[7] - pb + (b << 30)); pb = b;
	pb += r2[8]; b = lt_modm(r1[8], pb); r[8] = (r1[8] - pb + (b << 24));

	reduce256_modm(r);
	reduce256_modm(r);
}

/* addition modulo m */
static void
add256_modm(bignum256modm r, const bignum256modm x, const bignum256modm y) {
	bignum256modm_element_t c;

	c  = x[0] + y[0]; r[0] = c & 0x3fffffff; c >>= 30;
	c += x[1] + y[1]; r[1] = c & 0x3fffffff; c >>= 30;
	c += x[2] + y[2]; r[2] = c & 0x3fffffff; c >>= 30;
	c += x[3] + y[3]; r[3] = c & 0x3fffffff; c >>= 30;
	c += x[4] + y[4]; r[4] = c & 0x3fffffff; c >>= 30;
	c += x[5] + y[5]; r[5] = c & 0x3fffffff; c >>= 30;
	c += x[6] + y[6]; r[6] = c & 0x3fffffff; c >>= 30;
	c += x[7] + y[7]; r[7] = c & 0x3fffffff; c >>= 30;
	c += x[8] + y[8]; r[8] = c;

	reduce256_modm(r);
}

/* multiplication modulo m */
static void 
mul256_modm(bignum256modm r, const bignum256modm x, const bignum256modm y) {
	bignum256modm r1, q1;
	uint64_t c;
	bignum256modm_element_t f;

	/* r1 = (x mod 256^(32+1)) = x mod (2^8)(31+1) = x & ((1 << 264) - 1)
	   q1 = x >> 248 = 264 bits = 9 30 bit elements */
	c = mul32x32_64(x[0], y[0]);
	f = (bignum256modm_element_t)c; r1[0] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[1]) + mul32x32_64(x[1], y[0]);
	f = (bignum256modm_element_t)c; r1[1] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[2]) + mul32x32_64(x[1], y[1]) + mul32x32_64(x[2], y[0]);
	f = (bignum256modm_element_t)c; r1[2] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[3]) + mul32x32_64(x[1], y[2]) + mul32x32_64(x[2], y[1]) + mul32x32_64(x[3], y[0]);
	f = (bignum256modm_element_t)c; r1[3] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[4]) + mul32x32_64(x[1], y[3]) + mul32x32_64(x[2], y[2]) + mul32x32_64(x[3], y[1]) + mul32x32_64(x[4], y[0]);
	f = (bignum256modm_element_t)c; r1[4] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[5]) + mul32x32_64(x[1], y[4]) + mul32x32_64(x[2], y[3]) + mul32x32_64(x[3], y[2]) + mul32x32_64(x[4], y[1]) + mul32x32_64(x[5], y[0]);
	f = (bignum256modm_element_t)c; r1[5] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[6]) + mul32x32_64(x[1], y[5]) + mul32x32_64(x[2], y[4]) + mul32x32_64(x[3], y[3]) + mul32x32_64(x[4], y[2]) + mul32x32_64(x[5], y[1]) + mul32x32_64(x[6], y[0]);
	f = (bignum256modm_element_t)c; r1[6] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[7]) + mul32x32_64(x[1], y[6]) + mul32x32_64(x[2], y[5]) + mul32x32_64(x[3], y[4]) + mul32x32_64(x[4], y[3]) + mul32x32_64(x[5], y[2]) + mul32x32_64(x[6], y[1]) + mul32x32_64(x[7], y[0]);
	f = (bignum256modm_element_t)c; r1[7] = (f & 0x3fffffff); c >>= 30;
	c += mul32x32_64(x[0], y[8]) + mul32x32_64(x[1], y[7]) + mul32x32_64(x[2], y[6]) + mul32x32_64(x[3], y[5]) + mul32x32_64(x[4], y[4]) + mul32x32_64(x[5], y[3]) + mul32x32_64(x[6], y[2]) + mul32x32_64(x[7], y[1]) + mul32x32_64(x[8], y[0]);
	f = (bignum256modm_element_t)c; r1[8] = (f & 0x00ffffff); q1[0] = (f >> 8) & 0x3fffff; c >>= 30;
	c += mul32x32_64(x[1], y[8]) + mul32x32_64(x[2], y[7]) + mul32x32_64(x[3], y[6]) + mul32x32_64(x[4], y[5]) + mul32x32_64(x[5], y[4]) + mul32x32_64(x[6], y[3]) + mul32x32_64(x[7], y[2]) + mul32x32_64(x[8], y[1]);
	f = (bignum256modm_element_t)c; q1[0] = (q1[0] | (f << 22)) & 0x3fffffff; q1[1] = (f >> 8) & 0x3fffff; c >>= 30;	
	c += mul32x32_64(x[2], y[8]) + mul32x32_64(x[3], y[7]) + mul32x32_64(x[4], y[6]) + mul32x32_64(x[5], y[5]) + mul32x32_64(x[6], y[4]) + mul32x32_64(x[7], y[3]) + mul32x32_64(x[8], y[2]);
	f = (bignum256modm_element_t)c; q1[1] = (q1[1] | (f << 22)) & 0x3fffffff; q1[2] = (f >> 8) & 0x3fffff; c >>= 30;	
	c += mul32x32_64(x[3], y[8]) + mul32x32_64(x[4], y[7]) + mul32x32_64(x[5], y[6]) + mul32x32_64(x[6], y[5]) + mul32x32_64(x[7], y[4]) + mul32x32_64(x[8], y[3]);
	f = (bignum256modm_element_t)c; q1[2] = (q1[2] | (f << 22)) & 0x3fffffff; q1[3] = (f >> 8) & 0x3fffff; c >>= 30;	
	c += mul32x32_64(x[4], y[8]) + mul32x32_64(x[5], y[7]) + mul32x32_64(x[6], y[6]) + mul32x32_64(x[7], y[5]) + mul32x32_64(x[8], y[4]);
	f = (bignum256modm_element_t)c; q1[3] = (q1[3] | (f << 22)) & 0x3fffffff; q1[4] = (f >> 8) & 0x3fffff; c >>= 30;	
	c += mul32x32_64(x[5], y[8]) + mul32x32_64(x[6], y[7]) + mul32x32_64(x[7], y[6]) + mul32x32_64(x[8], y[5]);
	f = (bignum256modm_element_t)c; q1[4] = (q1[4] | (f << 22)) & 0x3fffffff; q1[5] = (f >> 8) & 0x3fffff; c >>= 30;
	c += mul32x32_64(x[6], y[8]) + mul32x32_64(x[7], y[7]) + mul32x32_64(x[8], y[6]);
	f = (bignum256modm_element_t)c; q1[5] = (q1[5] | (f << 22)) & 0x3fffffff; q1[6] = (f >> 8) & 0x3fffff; c >>= 30;
	c += mul32x32_64(x[7], y[8]) + mul32x32_64(x[8], y[7]);
	f = (bignum256modm_element_t)c; q1[6] = (q1[6] | (f << 22)) & 0x3fffffff; q1[7] = (f >> 8) & 0x3fffff; c >>= 30;
	c += mul32x32_64(x[8], y[8]);
	f = (bignum256modm_element_t)c; q1[7] = (q1[7] | (f << 22)) & 0x3fffffff; q1[8] = (f >> 8) & 0x3fffff;

	barrett_reduce256_modm(r, q1, r1);
}

static void
expand256_modm(bignum256modm out, const unsigned char *in, size_t len) {
	unsigned char work[64] = {0};
	bignum256modm_element_t x[16];
	bignum256modm q1;

	memcpy(work, in, len);
	x[0] = U8TO32_LE(work +  0);
	x[1] = U8TO32_LE(work +  4);
	x[2] = U8TO32_LE(work +  8);
	x[3] = U8TO32_LE(work + 12);
	x[4] = U8TO32_LE(work + 16);
	x[5] = U8TO32_LE(work + 20);
	x[6] = U8TO32_LE(work + 24);
	x[7] = U8TO32_LE(work + 28);
	x[8] = U8TO32_LE(work + 32);
	x[9] = U8TO32_LE(work + 36);
	x[10] = U8TO32_LE(work + 40);
	x[11] = U8TO32_LE(work + 44);
	x[12] = U8TO32_LE(work + 48);
	x[13] = U8TO32_LE(work + 52);
	x[14] = U8TO32_LE(work + 56);
	x[15] = U8TO32_LE(work + 60);

	/* r1 = (x mod 256^(32+1)) = x mod (2^8)(31+1) = x & ((1 << 264) - 1) */
	out[0] = (                         x[0]) & 0x3fffffff;
	out[1] = ((x[ 0] >> 30) | (x[ 1] <<  2)) & 0x3fffffff;
	out[2] = ((x[ 1] >> 28) | (x[ 2] <<  4)) & 0x3fffffff;
	out[3] = ((x[ 2] >> 26) | (x[ 3] <<  6)) & 0x3fffffff;
	out[4] = ((x[ 3] >> 24) | (x[ 4] <<  8)) & 0x3fffffff;
	out[5] = ((x[ 4] >> 22) | (x[ 5] << 10)) & 0x3fffffff;
	out[6] = ((x[ 5] >> 20) | (x[ 6] << 12)) & 0x3fffffff;
	out[7] = ((x[ 6] >> 18) | (x[ 7] << 14)) & 0x3fffffff;
	out[8] = ((x[ 7] >> 16) | (x[ 8] << 16)) & 0x00ffffff;

	/* 8*31 = 248 bits, no need to reduce */
	if (len < 32)
		return;

	/* q1 = x >> 248 = 264 bits = 9 30 bit elements */
	q1[0] = ((x[ 7] >> 24) | (x[ 8] <<  8)) & 0x3fffffff;
	q1[1] = ((x[ 8] >> 22) | (x[ 9] << 10)) & 0x3fffffff;
	q1[2] = ((x[ 9] >> 20) | (x[10] << 12)) & 0x3fffffff;
	q1[3] = ((x[10] >> 18) | (x[11] << 14)) & 0x3fffffff;
	q1[4] = ((x[11] >> 16) | (x[12] << 16)) & 0x3fffffff;
	q1[5] = ((x[12] >> 14) | (x[13] << 18)) & 0x3fffffff;
	q1[6] = ((x[13] >> 12) | (x[14] << 20)) & 0x3fffffff;
	q1[7] = ((x[14] >> 10) | (x[15] << 22)) & 0x3fffffff;
	q1[8] = ((x[15] >>  8)                );	

	barrett_reduce256_modm(out, q1, out);
}

static void
expand_raw256_modm(bignum256modm out, const unsigned char in[32]) {
	bignum256modm_element_t x[8];

	x[0] = U8TO32_LE(in +  0);
	x[1] = U8TO32_LE(in +  4);
	x[2] = U8TO32_LE(in +  8);
	x[3] = U8TO32_LE(in + 12);
	x[4] = U8TO32_LE(in + 16);
	x[5] = U8TO32_LE(in + 20);
	x[6] = U8TO32_LE(in + 24);
	x[7] = U8TO32_LE(in + 28);

	out[0] = (                         x[0]) & 0x3fffffff;
	out[1] = ((x[ 0] >> 30) | (x[ 1] <<  2)) & 0x3fffffff;
	out[2] = ((x[ 1] >> 28) | (x[ 2] <<  4)) & 0x3fffffff;
	out[3] = ((x[ 2] >> 26) | (x[ 3] <<  6)) & 0x3fffffff;
	out[4] = ((x[ 3] >> 24) | (x[ 4] <<  8)) & 0x3fffffff;
	out[5] = ((x[ 4] >> 22) | (x[ 5] << 10)) & 0x3fffffff;
	out[6] = ((x[ 5] >> 20) | (x[ 6] << 12)) & 0x3fffffff;
	out[7] = ((x[ 6] >> 18) | (x[ 7] << 14)) & 0x3fffffff;
	out[8] = ((x[ 7] >> 16)                ) & 0x0000ffff;
}

static void
contract256_modm(unsigned char out[32], const bignum256modm in) {
	U32TO8_LE(out +  0, (in[0]      ) | (in[1] << 30));
	U32TO8_LE(out +  4, (in[1] >>  2) | (in[2] << 28));
	U32TO8_LE(out +  8, (in[2] >>  4) | (in[3] << 26));
	U32TO8_LE(out + 12, (in[3] >>  6) | (in[4] << 24));
	U32TO8_LE(out + 16, (in[4] >>  8) | (in[5] << 22));
	U32TO8_LE(out + 20, (in[5] >> 10) | (in[6] << 20));
	U32TO8_LE(out + 24, (in[6] >> 12) | (in[7] << 18));
	U32TO8_LE(out + 28, (in[7] >> 14) | (in[8] << 16));
}



static void
contract256_window4_modm(signed char r[64], const bignum256modm in) {
	char carry;
	signed char *quads = r;
	bignum256modm_element_t i, j, v;

	for (i = 0; i < 8; i += 2) {
		v = in[i];
		for (j = 0; j < 7; j++) {
			*quads++ = (v & 15);
			v >>= 4;
		}
		v |= (in[i+1] << 2);
		for (j = 0; j < 8; j++) {
			*quads++ = (v & 15);
			v >>= 4;
		}
	}
	v = in[8];
	*quads++ = (v & 15); v >>= 4;
	*quads++ = (v & 15); v >>= 4;
	*quads++ = (v & 15); v >>= 4;
	*quads++ = (v & 15); v >>= 4;

	/* making it signed */
	carry = 0;
	for(i = 0; i < 63; i++) {
		r[i] += carry;
		r[i+1] += (r[i] >> 4);
		r[i] &= 15;
		carry = (r[i] >> 3);
		r[i] -= (carry << 4);
	}
	r[63] += carry;
}

static void
contract256_slidingwindow_modm(signed char r[256], const bignum256modm s, int windowsize) {
	int i,j,k,b;
	int m = (1 << (windowsize - 1)) - 1;
        const int soplen = 256;
	signed char *bits = r;
	bignum256modm_element_t v;

	/* first put the binary expansion into r  */
	for (i = 0; i < 8; i++) {
		v = s[i];
		for (j = 0; j < 30; j++, v >>= 1)
			*bits++ = (v & 1);
	}
	v = s[8];
	for (j = 0; j < 16; j++, v >>= 1)
		*bits++ = (v & 1);

	/* Making it sliding window */
	for (j = 0; j < soplen; j++) {
		if (!r[j])
			continue;

		for (b = 1; (b < (soplen - j)) && (b <= 6); b++) {
			if ((r[j] + (r[j + b] << b)) <= m) {
				r[j] += r[j + b] << b;
				r[j + b] = 0;
			} else if ((r[j] - (r[j + b] << b)) >= -m) {
				r[j] -= r[j + b] << b;
				for (k = j + b; k < soplen; k++) {
					if (!r[k]) {
						r[k] = 1;
						break;
					}
					r[k] = 0;
				}
			} else if (r[j + b]) {
				break;
			}
		}
	}
}


/*
	helpers for batch verifcation, are allowed to be vartime
*/

/* out = a - b, a must be larger than b */
static void
sub256_modm_batch(bignum256modm out, const bignum256modm a, const bignum256modm b, size_t limbsize) {
	size_t i = 0;
	bignum256modm_element_t carry = 0;
	switch (limbsize) {
		case 8: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 7: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 6: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 5: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 4: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 3: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 2: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 1: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 31); out[i] &= 0x3fffffff; i++; FALLTHROUGH;
		case 0: 
		default: out[i] = (a[i] - b[i]) - carry;
	}
}


/* is a < b */
static int
lt256_modm_batch(const bignum256modm a, const bignum256modm b, size_t limbsize) {
	switch (limbsize) {
		case 8: if (a[8] > b[8]) return 0; if (a[8] < b[8]) return 1; FALLTHROUGH;
		case 7: if (a[7] > b[7]) return 0; if (a[7] < b[7]) return 1; FALLTHROUGH;
		case 6: if (a[6] > b[6]) return 0; if (a[6] < b[6]) return 1; FALLTHROUGH;
		case 5: if (a[5] > b[5]) return 0; if (a[5] < b[5]) return 1; FALLTHROUGH;
		case 4: if (a[4] > b[4]) return 0; if (a[4] < b[4]) return 1; FALLTHROUGH;
		case 3: if (a[3] > b[3]) return 0; if (a[3] < b[3]) return 1; FALLTHROUGH;
		case 2: if (a[2] > b[2]) return 0; if (a[2] < b[2]) return 1; FALLTHROUGH;
		case 1: if (a[1] > b[1]) return 0; if (a[1] < b[1]) return 1; FALLTHROUGH;
		case 0: if (a[0] > b[0]) return 0; if (a[0] < b[0]) return 1;
	}
	return 0;
}

/* is a <= b */
static int
lte256_modm_batch(const bignum256modm a, const bignum256modm b, size_t limbsize) {
	switch (limbsize) {
		case 8: if (a[8] > b[8]) return 0; if (a[8] < b[8]) return 1; FALLTHROUGH;
		case 7: if (a[7] > b[7]) return 0; if (a[7] < b[7]) return 1; FALLTHROUGH;
		case 6: if (a[6] > b[6]) return 0; if (a[6] < b[6]) return 1; FALLTHROUGH;
		case 5: if (a[5] > b[5]) return 0; if (a[5] < b[5]) return 1; FALLTHROUGH;
		case 4: if (a[4] > b[4]) return 0; if (a[4] < b[4]) return 1; FALLTHROUGH;
		case 3: if (a[3] > b[3]) return 0; if (a[3] < b[3]) return 1; FALLTHROUGH;
		case 2: if (a[2] > b[2]) return 0; if (a[2] < b[2]) return 1; FALLTHROUGH;
		case 1: if (a[1] > b[1]) return 0; if (a[1] < b[1]) return 1; FALLTHROUGH;
		case 0: if (a[0] > b[0]) return 0; if (a[0] < b[0]) return 1;
	}
	return 1;
}


/* is a == 0 */
static int
iszero256_modm_batch(const bignum256modm a) {
	size_t i;
	for (i = 0; i < 9; i++)
		if (a[i])
			return 0;
	return 1;
}

/* is a == 1 */
static int
isone256_modm_batch(const bignum256modm a) {
	size_t i;
	if (a[0] != 1)
		return 0;
	for (i = 1; i < 9; i++)
		if (a[i])
			return 0;
	return 1;
}

/* can a fit in to (at most) 128 bits */
static int
isatmost128bits256_modm_batch(const bignum256modm a) {
	uint32_t mask =
		((a[8]             )  | /*  16 */
		 (a[7]             )  | /*  46 */
		 (a[6]             )  | /*  76 */
		 (a[5]             )  | /* 106 */
		 (a[4] & 0x3fffff00));  /* 128 */

	return (mask == 0);
}
