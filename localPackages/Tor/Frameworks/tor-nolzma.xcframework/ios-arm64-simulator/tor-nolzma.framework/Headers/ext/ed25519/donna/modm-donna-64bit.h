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

#define bignum256modm_bits_per_limb 56
#define bignum256modm_limb_size 5

typedef uint64_t bignum256modm_element_t;
typedef bignum256modm_element_t bignum256modm[5];

static const bignum256modm modm_m = {
	0x12631a5cf5d3ed, 
	0xf9dea2f79cd658, 
	0x000000000014de, 
	0x00000000000000, 
	0x00000010000000
};

static const bignum256modm modm_mu = {
	0x9ce5a30a2c131b,
	0x215d086329a7ed,
	0xffffffffeb2106,
	0xffffffffffffff,
	0x00000fffffffff
};

static bignum256modm_element_t
lt_modm(bignum256modm_element_t a, bignum256modm_element_t b) {
	return (a - b) >> 63;
}

static void
reduce256_modm(bignum256modm r) {
	bignum256modm t;
	bignum256modm_element_t b = 0, pb, mask;

	/* t = r - m */
	pb = 0;
	pb += modm_m[0]; b = lt_modm(r[0], pb); t[0] = (r[0] - pb + (b << 56)); pb = b;
	pb += modm_m[1]; b = lt_modm(r[1], pb); t[1] = (r[1] - pb + (b << 56)); pb = b;
	pb += modm_m[2]; b = lt_modm(r[2], pb); t[2] = (r[2] - pb + (b << 56)); pb = b;
	pb += modm_m[3]; b = lt_modm(r[3], pb); t[3] = (r[3] - pb + (b << 56)); pb = b;
	pb += modm_m[4]; b = lt_modm(r[4], pb); t[4] = (r[4] - pb + (b << 32)); 

	/* keep r if r was smaller than m */
	mask = b - 1;

	r[0] ^= mask & (r[0] ^ t[0]);
	r[1] ^= mask & (r[1] ^ t[1]);
	r[2] ^= mask & (r[2] ^ t[2]);
	r[3] ^= mask & (r[3] ^ t[3]);
	r[4] ^= mask & (r[4] ^ t[4]);
}

static void
barrett_reduce256_modm(bignum256modm r, const bignum256modm q1, const bignum256modm r1) {
	bignum256modm q3, r2;
	uint128_t c, mul;
	bignum256modm_element_t f, b, pb;

	/* q1 = x >> 248 = 264 bits = 5 56 bit elements
	   q2 = mu * q1
	   q3 = (q2 / 256(32+1)) = q2 / (2^8)^(32+1) = q2 >> 264 */
	mul64x64_128(c, modm_mu[0], q1[3])                 mul64x64_128(mul, modm_mu[3], q1[0]) add128(c, mul) mul64x64_128(mul, modm_mu[1], q1[2]) add128(c, mul) mul64x64_128(mul, modm_mu[2], q1[1]) add128(c, mul) shr128(f, c, 56);
	mul64x64_128(c, modm_mu[0], q1[4]) add128_64(c, f) mul64x64_128(mul, modm_mu[4], q1[0]) add128(c, mul) mul64x64_128(mul, modm_mu[3], q1[1]) add128(c, mul) mul64x64_128(mul, modm_mu[1], q1[3]) add128(c, mul) mul64x64_128(mul, modm_mu[2], q1[2]) add128(c, mul)
	f = lo128(c); q3[0] = (f >> 40) & 0xffff; shr128(f, c, 56);
	mul64x64_128(c, modm_mu[4], q1[1]) add128_64(c, f) mul64x64_128(mul, modm_mu[1], q1[4]) add128(c, mul) mul64x64_128(mul, modm_mu[2], q1[3]) add128(c, mul) mul64x64_128(mul, modm_mu[3], q1[2]) add128(c, mul)
	f = lo128(c); q3[0] |= (f << 16) & 0xffffffffffffff; q3[1] = (f >> 40) & 0xffff; shr128(f, c, 56);
	mul64x64_128(c, modm_mu[4], q1[2]) add128_64(c, f) mul64x64_128(mul, modm_mu[2], q1[4]) add128(c, mul) mul64x64_128(mul, modm_mu[3], q1[3]) add128(c, mul)
	f = lo128(c); q3[1] |= (f << 16) & 0xffffffffffffff; q3[2] = (f >> 40) & 0xffff; shr128(f, c, 56);
	mul64x64_128(c, modm_mu[4], q1[3]) add128_64(c, f) mul64x64_128(mul, modm_mu[3], q1[4]) add128(c, mul)
	f = lo128(c); q3[2] |= (f << 16) & 0xffffffffffffff; q3[3] = (f >> 40) & 0xffff; shr128(f, c, 56);
	mul64x64_128(c, modm_mu[4], q1[4]) add128_64(c, f)
	f = lo128(c); q3[3] |= (f << 16) & 0xffffffffffffff; q3[4] = (f >> 40) & 0xffff; shr128(f, c, 56);
	q3[4] |= (f << 16);

	mul64x64_128(c, modm_m[0], q3[0]) 
	r2[0] = lo128(c) & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, modm_m[0], q3[1]) add128_64(c, f) mul64x64_128(mul, modm_m[1], q3[0]) add128(c, mul)
	r2[1] = lo128(c) & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, modm_m[0], q3[2]) add128_64(c, f) mul64x64_128(mul, modm_m[2], q3[0]) add128(c, mul) mul64x64_128(mul, modm_m[1], q3[1]) add128(c, mul)
	r2[2] = lo128(c) & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, modm_m[0], q3[3]) add128_64(c, f) mul64x64_128(mul, modm_m[3], q3[0]) add128(c, mul) mul64x64_128(mul, modm_m[1], q3[2]) add128(c, mul) mul64x64_128(mul, modm_m[2], q3[1]) add128(c, mul)
	r2[3] = lo128(c) & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, modm_m[0], q3[4]) add128_64(c, f) mul64x64_128(mul, modm_m[4], q3[0]) add128(c, mul) mul64x64_128(mul, modm_m[3], q3[1]) add128(c, mul) mul64x64_128(mul, modm_m[1], q3[3]) add128(c, mul) mul64x64_128(mul, modm_m[2], q3[2]) add128(c, mul)
	r2[4] = lo128(c) & 0x0000ffffffffff;

	pb = 0;
	pb += r2[0]; b = lt_modm(r1[0], pb); r[0] = (r1[0] - pb + (b << 56)); pb = b;
	pb += r2[1]; b = lt_modm(r1[1], pb); r[1] = (r1[1] - pb + (b << 56)); pb = b;
	pb += r2[2]; b = lt_modm(r1[2], pb); r[2] = (r1[2] - pb + (b << 56)); pb = b;
	pb += r2[3]; b = lt_modm(r1[3], pb); r[3] = (r1[3] - pb + (b << 56)); pb = b;
	pb += r2[4]; b = lt_modm(r1[4], pb); r[4] = (r1[4] - pb + (b << 40)); 

	reduce256_modm(r);
	reduce256_modm(r);
}


static void
add256_modm(bignum256modm r, const bignum256modm x, const bignum256modm y) {
	bignum256modm_element_t c;

	c  = x[0] + y[0]; r[0] = c & 0xffffffffffffff; c >>= 56;
	c += x[1] + y[1]; r[1] = c & 0xffffffffffffff; c >>= 56;
	c += x[2] + y[2]; r[2] = c & 0xffffffffffffff; c >>= 56;
	c += x[3] + y[3]; r[3] = c & 0xffffffffffffff; c >>= 56;
	c += x[4] + y[4]; r[4] = c;

	reduce256_modm(r);
}

static void
mul256_modm(bignum256modm r, const bignum256modm x, const bignum256modm y) {
	bignum256modm q1, r1;
	uint128_t c, mul;
	bignum256modm_element_t f;

	mul64x64_128(c, x[0], y[0])
	f = lo128(c); r1[0] = f & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[0], y[1]) add128_64(c, f) mul64x64_128(mul, x[1], y[0]) add128(c, mul) 
	f = lo128(c); r1[1] = f & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[0], y[2]) add128_64(c, f) mul64x64_128(mul, x[2], y[0]) add128(c, mul) mul64x64_128(mul, x[1], y[1]) add128(c, mul) 
	f = lo128(c); r1[2] = f & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[0], y[3]) add128_64(c, f) mul64x64_128(mul, x[3], y[0]) add128(c, mul) mul64x64_128(mul, x[1], y[2]) add128(c, mul) mul64x64_128(mul, x[2], y[1]) add128(c, mul) 
	f = lo128(c); r1[3] = f & 0xffffffffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[0], y[4]) add128_64(c, f) mul64x64_128(mul, x[4], y[0]) add128(c, mul) mul64x64_128(mul, x[3], y[1]) add128(c, mul) mul64x64_128(mul, x[1], y[3]) add128(c, mul) mul64x64_128(mul, x[2], y[2]) add128(c, mul) 
	f = lo128(c); r1[4] = f & 0x0000ffffffffff; q1[0] = (f >> 24) & 0xffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[4], y[1]) add128_64(c, f) mul64x64_128(mul, x[1], y[4]) add128(c, mul) mul64x64_128(mul, x[2], y[3]) add128(c, mul) mul64x64_128(mul, x[3], y[2]) add128(c, mul) 
	f = lo128(c); q1[0] |= (f << 32) & 0xffffffffffffff; q1[1] = (f >> 24) & 0xffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[4], y[2]) add128_64(c, f) mul64x64_128(mul, x[2], y[4]) add128(c, mul) mul64x64_128(mul, x[3], y[3]) add128(c, mul) 
	f = lo128(c); q1[1] |= (f << 32) & 0xffffffffffffff; q1[2] = (f >> 24) & 0xffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[4], y[3]) add128_64(c, f) mul64x64_128(mul, x[3], y[4]) add128(c, mul) 
	f = lo128(c); q1[2] |= (f << 32) & 0xffffffffffffff; q1[3] = (f >> 24) & 0xffffffff; shr128(f, c, 56);
	mul64x64_128(c, x[4], y[4]) add128_64(c, f)
	f = lo128(c); q1[3] |= (f << 32) & 0xffffffffffffff; q1[4] = (f >> 24) & 0xffffffff; shr128(f, c, 56);
	q1[4] |= (f << 32);

	barrett_reduce256_modm(r, q1, r1);
}

static void
expand256_modm(bignum256modm out, const unsigned char *in, size_t len) {
	unsigned char work[64] = {0};
	bignum256modm_element_t x[16];
	bignum256modm q1;

	memcpy(work, in, len);
	x[0] = U8TO64_LE(work +  0);
	x[1] = U8TO64_LE(work +  8);
	x[2] = U8TO64_LE(work + 16);
	x[3] = U8TO64_LE(work + 24);
	x[4] = U8TO64_LE(work + 32);
	x[5] = U8TO64_LE(work + 40);
	x[6] = U8TO64_LE(work + 48);
	x[7] = U8TO64_LE(work + 56);

	/* r1 = (x mod 256^(32+1)) = x mod (2^8)(31+1) = x & ((1 << 264) - 1) */
	out[0] = (                         x[0]) & 0xffffffffffffff;
	out[1] = ((x[ 0] >> 56) | (x[ 1] <<  8)) & 0xffffffffffffff;
	out[2] = ((x[ 1] >> 48) | (x[ 2] << 16)) & 0xffffffffffffff;
	out[3] = ((x[ 2] >> 40) | (x[ 3] << 24)) & 0xffffffffffffff;
	out[4] = ((x[ 3] >> 32) | (x[ 4] << 32)) & 0x0000ffffffffff;

	/* under 252 bits, no need to reduce */
	if (len < 32)
		return;

	/* q1 = x >> 248 = 264 bits */
	q1[0] = ((x[ 3] >> 56) | (x[ 4] <<  8)) & 0xffffffffffffff;
	q1[1] = ((x[ 4] >> 48) | (x[ 5] << 16)) & 0xffffffffffffff;
	q1[2] = ((x[ 5] >> 40) | (x[ 6] << 24)) & 0xffffffffffffff;
	q1[3] = ((x[ 6] >> 32) | (x[ 7] << 32)) & 0xffffffffffffff;
	q1[4] = ((x[ 7] >> 24)                );

	barrett_reduce256_modm(out, q1, out);
}

static void
expand_raw256_modm(bignum256modm out, const unsigned char in[32]) {
	bignum256modm_element_t x[4];

	x[0] = U8TO64_LE(in +  0);
	x[1] = U8TO64_LE(in +  8);
	x[2] = U8TO64_LE(in + 16);
	x[3] = U8TO64_LE(in + 24);

	out[0] = (                         x[0]) & 0xffffffffffffff;
	out[1] = ((x[ 0] >> 56) | (x[ 1] <<  8)) & 0xffffffffffffff;
	out[2] = ((x[ 1] >> 48) | (x[ 2] << 16)) & 0xffffffffffffff;
	out[3] = ((x[ 2] >> 40) | (x[ 3] << 24)) & 0xffffffffffffff;
	out[4] = ((x[ 3] >> 32)                ) & 0x000000ffffffff;
}

static void
contract256_modm(unsigned char out[32], const bignum256modm in) {
	U64TO8_LE(out +  0, (in[0]      ) | (in[1] << 56));
	U64TO8_LE(out +  8, (in[1] >>  8) | (in[2] << 48));
	U64TO8_LE(out + 16, (in[2] >> 16) | (in[3] << 40));
	U64TO8_LE(out + 24, (in[3] >> 24) | (in[4] << 32));
}

static void
contract256_window4_modm(signed char r[64], const bignum256modm in) {
	char carry;
	signed char *quads = r;
	bignum256modm_element_t i, j, v, m;

	for (i = 0; i < 5; i++) {
		v = in[i];
		m = (i == 4) ? 8 : 14;
		for (j = 0; j < m; j++) {
			*quads++ = (v & 15);
			v >>= 4;
		}
	}

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
	for (i = 0; i < 4; i++) {
		v = s[i];
		for (j = 0; j < 56; j++, v >>= 1)
			*bits++ = (v & 1);
	}
	v = s[4];
	for (j = 0; j < 32; j++, v >>= 1)
		*bits++ = (v & 1);

	/* Making it sliding window */
	for (j = 0; j < soplen; j++) {
		if (!r[j])
			continue;

		for (b = 1; (b < (soplen - j)) && (b <= 6); b++) {
			/* XXX Tor: coverity scan says that r[j+b] can
			 * overflow, but that's not possible: b < (soplen-j)
			 * guarantees that b + j < soplen, so b+j < 256,
			 * so the index doesn't overflow. */
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
		case 4: out[i] = (a[i] - b[i])        ; carry = (out[i] >> 63); out[i] &= 0xffffffffffffff; i++; FALLTHROUGH;
		case 3: out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 63); out[i] &= 0xffffffffffffff; i++; FALLTHROUGH;
		case 2:	out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 63); out[i] &= 0xffffffffffffff; i++; FALLTHROUGH;
		case 1:	out[i] = (a[i] - b[i]) - carry; carry = (out[i] >> 63); out[i] &= 0xffffffffffffff; i++; FALLTHROUGH;
		case 0: 
		default: out[i] = (a[i] - b[i]) - carry;
	}
}


/* is a < b */
static int
lt256_modm_batch(const bignum256modm a, const bignum256modm b, size_t limbsize) {
	size_t i = 0;
	bignum256modm_element_t t, carry = 0;
	switch (limbsize) {
		case 4: t = (a[i] - b[i])        ; carry = (t >> 63); i++; FALLTHROUGH;
		case 3: t = (a[i] - b[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 2: t = (a[i] - b[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 1: t = (a[i] - b[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 0: t = (a[i] - b[i]) - carry; carry = (t >> 63);
	}
	return (int)carry;
}

/* is a <= b */
static int
lte256_modm_batch(const bignum256modm a, const bignum256modm b, size_t limbsize) {
	size_t i = 0;
	bignum256modm_element_t t, carry = 0;
	switch (limbsize) {
		case 4: t = (b[i] - a[i])        ; carry = (t >> 63); i++; FALLTHROUGH;
		case 3: t = (b[i] - a[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 2: t = (b[i] - a[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 1: t = (b[i] - a[i]) - carry; carry = (t >> 63); i++; FALLTHROUGH;
		case 0: t = (b[i] - a[i]) - carry; carry = (t >> 63);
	}
	return (int)!carry;
}

/* is a == 0 */
static int
iszero256_modm_batch(const bignum256modm a) {
	size_t i;
	for (i = 0; i < 5; i++)
		if (a[i])
			return 0;
	return 1;
}

/* is a == 1 */
static int
isone256_modm_batch(const bignum256modm a) {
	size_t i;
	for (i = 0; i < 5; i++)
		if (a[i] != ((i) ? 0 : 1))
			return 0;
	return 1;
}

/* can a fit in to (at most) 128 bits */
static int
isatmost128bits256_modm_batch(const bignum256modm a) {
	uint64_t mask =
		((a[4]                   )  | /*  32 */
		 (a[3]                   )  | /*  88 */
		 (a[2] & 0xffffffffff0000));

	return (mask == 0);
}
