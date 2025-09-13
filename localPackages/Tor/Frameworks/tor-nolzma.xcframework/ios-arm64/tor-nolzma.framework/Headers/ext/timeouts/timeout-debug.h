/*
 * D E B U G  R O U T I N E S
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#if TIMEOUT_DEBUG - 0
#include <stdlib.h>
#include <stdio.h>

#undef TIMEOUT_DEBUG
#define TIMEOUT_DEBUG 1
#define DEBUG_LEVEL timeout_debug

static int timeout_debug;

#define SAYit_(lvl, fmt, ...) do { \
	if (DEBUG_LEVEL >= (lvl)) \
		fprintf(stderr, fmt "%s", __FILE__, __LINE__, __func__, __VA_ARGS__); \
} while (0)

#define SAYit(lvl, ...) SAYit_((lvl), "%s:%d:%s: " __VA_ARGS__, "\n")

#define PANIC(...) do { \
	SAYit(0, __VA_ARGS__); \
	_Exit(EXIT_FAILURE); \
} while (0)
#else
#undef TIMEOUT_DEBUG
#define TIMEOUT_DEBUG 0
#define DEBUG_LEVEL 0

#define SAYit(...) (void)0
#endif

#define SAY(...) SAYit(1, __VA_ARGS__)
#define HAI SAY("HAI")


static inline char *fmt_(char *buf, uint64_t ts, int wheel_bit, int wheel_num) {
	char *p = buf;
	int wheel, n, i;

	for (wheel = wheel_num - 2; wheel >= 0; wheel--) {
		n = ((1 << wheel_bit) - 1) & (ts >> (wheel * WHEEL_BIT));

		for (i = wheel_bit - 1; i >= 0; i--) {
			*p++ = '0' + !!(n & (1 << i));
		}

		if (wheel != 0)
			*p++ = ':';
	}

	*p = 0;

	return buf;
} /* fmt_() */

#define fmt(ts) fmt_(((char[((1 << WHEEL_BIT) * WHEEL_NUM) + WHEEL_NUM + 1]){ 0 }), (ts), WHEEL_BIT, WHEEL_NUM)


static inline char *bin64_(char *buf, uint64_t n, int wheel_bit) {
	char *p = buf;
	int i;

	for (i = 0; i < (1 << wheel_bit); i++) {
		*p++ = "01"[0x1 & (n >> (((1 << wheel_bit) - 1) - i))];
	}

	*p = 0;

	return buf;
} /* bin64_() */

#define bin64(ts) bin64_(((char[((1 << WHEEL_BIT) * WHEEL_NUM) + 1]){ 0 }), (ts), WHEEL_BIT)


