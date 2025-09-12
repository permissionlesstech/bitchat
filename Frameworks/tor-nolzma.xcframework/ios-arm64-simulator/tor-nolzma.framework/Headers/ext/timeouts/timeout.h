/* ==========================================================================
 * timeout.h - Tickless hierarchical timing wheel.
 * --------------------------------------------------------------------------
 * Copyright (c) 2013, 2014  William Ahern
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to permit
 * persons to whom the Software is furnished to do so, subject to the
 * following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
 * NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 * DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
 * USE OR OTHER DEALINGS IN THE SOFTWARE.
 * ==========================================================================
 */
#ifndef TIMEOUT_H
#define TIMEOUT_H

#include <stdbool.h>    /* bool */
#include <stdio.h>      /* FILE */

#include <inttypes.h>   /* PRIu64 PRIx64 PRIX64 uint64_t */

#include "ext/tor_queue.h"  /* TAILQ(3) */


/*
 * V E R S I O N  I N T E R F A C E S
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#if !defined TIMEOUT_PUBLIC
#define TIMEOUT_PUBLIC
#endif

#define TIMEOUT_VERSION TIMEOUT_V_REL
#define TIMEOUT_VENDOR  "william@25thandClement.com"

#define TIMEOUT_V_REL 0x20160226
#define TIMEOUT_V_ABI 0x20160224
#define TIMEOUT_V_API 0x20160226

TIMEOUT_PUBLIC int timeout_version(void);

TIMEOUT_PUBLIC const char *timeout_vendor(void);

TIMEOUT_PUBLIC int timeout_v_rel(void);

TIMEOUT_PUBLIC int timeout_v_abi(void);

TIMEOUT_PUBLIC int timeout_v_api(void);


/*
 * I N T E G E R  T Y P E  I N T E R F A C E S
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#define TIMEOUT_C(n) UINT64_C(n)
#define TIMEOUT_PRIu PRIu64
#define TIMEOUT_PRIx PRIx64
#define TIMEOUT_PRIX PRIX64

#define TIMEOUT_mHZ TIMEOUT_C(1000)
#define TIMEOUT_uHZ TIMEOUT_C(1000000)
#define TIMEOUT_nHZ TIMEOUT_C(1000000000)

typedef uint64_t timeout_t;

#define timeout_error_t int /* for documentation purposes */


/*
 * C A L L B A C K  I N T E R F A C E
 *
 * Callback function parameters unspecified to make embedding into existing
 * applications easier.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#ifndef TIMEOUT_CB_OVERRIDE
struct timeout_cb_t {
	void (*fn)(void);
	void *arg;
}; /* struct timeout_cb_t */
#endif

/*
 * T I M E O U T  I N T E R F A C E S
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#ifndef TIMEOUT_DISABLE_INTERVALS
#define TIMEOUT_INT 0x01 /* interval (repeating) timeout */
#endif
#define TIMEOUT_ABS 0x02 /* treat timeout values as absolute */

#define TIMEOUT_INITIALIZER(flags) { (flags) }

#define timeout_setcb(to, fn, arg) do { \
	(to)->callback.fn = (fn);       \
	(to)->callback.arg = (arg);     \
} while (0)

struct timeout {
	int flags;

	timeout_t expires;
	/* absolute expiration time */

	struct timeout_list *pending;
	/* timeout list if pending on wheel or expiry queue */

	TOR_TAILQ_ENTRY(timeout) tqe;
	/* entry member for struct timeout_list lists */

#ifndef TIMEOUT_DISABLE_CALLBACKS
	struct timeout_cb_t callback;
	/* optional callback information */
#endif

#ifndef TIMEOUT_DISABLE_INTERVALS
	timeout_t interval;
	/* timeout interval if periodic */
#endif

#ifndef TIMEOUT_DISABLE_RELATIVE_ACCESS
	struct timeouts *timeouts;
	/* timeouts collection if member of */
#endif
}; /* struct timeout */


TIMEOUT_PUBLIC struct timeout *timeout_init(struct timeout *, int);
/* initialize timeout structure (same as TIMEOUT_INITIALIZER) */

#ifndef TIMEOUT_DISABLE_RELATIVE_ACCESS
TIMEOUT_PUBLIC bool timeout_pending(struct timeout *);
/* true if on timing wheel, false otherwise */

TIMEOUT_PUBLIC bool timeout_expired(struct timeout *);
/* true if on expired queue, false otherwise */

TIMEOUT_PUBLIC void timeout_del(struct timeout *);
/* remove timeout from any timing wheel (okay if not member of any) */
#endif

/*
 * T I M I N G  W H E E L  I N T E R F A C E S
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

struct timeouts;

TIMEOUT_PUBLIC struct timeouts *timeouts_open(timeout_t, timeout_error_t *);
/* open a new timing wheel, setting optional HZ (for float conversions) */

TIMEOUT_PUBLIC void timeouts_close(struct timeouts *);
/* destroy timing wheel */

TIMEOUT_PUBLIC timeout_t timeouts_hz(struct timeouts *);
/* return HZ setting (for float conversions) */

TIMEOUT_PUBLIC void timeouts_update(struct timeouts *, timeout_t);
/* update timing wheel with current absolute time */

TIMEOUT_PUBLIC void timeouts_step(struct timeouts *, timeout_t);
/* step timing wheel by relative time */

TIMEOUT_PUBLIC timeout_t timeouts_get_curtime(struct timeouts *);
/* Return the current tick. */

TIMEOUT_PUBLIC timeout_t timeouts_timeout(struct timeouts *);
/* return interval to next required update */

TIMEOUT_PUBLIC void timeouts_add(struct timeouts *, struct timeout *, timeout_t);
/* add timeout to timing wheel */

TIMEOUT_PUBLIC void timeouts_del(struct timeouts *, struct timeout *);
/* remove timeout from any timing wheel or expired queue (okay if on neither) */

TIMEOUT_PUBLIC struct timeout *timeouts_get(struct timeouts *);
/* return any expired timeout (caller should loop until NULL-return) */

TIMEOUT_PUBLIC bool timeouts_pending(struct timeouts *);
/* return true if any timeouts pending on timing wheel */

TIMEOUT_PUBLIC bool timeouts_expired(struct timeouts *);
/* return true if any timeouts on expired queue */

TIMEOUT_PUBLIC bool timeouts_check(struct timeouts *, FILE *);
/* return true if invariants hold. describes failures to optional file handle. */

#define TIMEOUTS_PENDING 0x10
#define TIMEOUTS_EXPIRED 0x20
#define TIMEOUTS_ALL     (TIMEOUTS_PENDING|TIMEOUTS_EXPIRED)
#define TIMEOUTS_CLEAR   0x40

#define TIMEOUTS_IT_INITIALIZER(flags) { (flags), 0, 0, 0, 0 }

#define TIMEOUTS_IT_INIT(cur, _flags) do {                              \
	(cur)->flags = (_flags);                                        \
	(cur)->pc = 0;                                                  \
} while (0)

struct timeouts_it {
	int flags;
	unsigned pc, i, j;
	struct timeout *to;
}; /* struct timeouts_it */

TIMEOUT_PUBLIC struct timeout *timeouts_next(struct timeouts *, struct timeouts_it *);
/* return next timeout in pending wheel or expired queue. caller can delete
 * the returned timeout, but should not otherwise manipulate the timing
 * wheel. in particular, caller SHOULD NOT delete any other timeout as that
 * could invalidate cursor state and trigger a use-after-free.
 */

#define TIMEOUTS_FOREACH(var, T, flags)                                 \
	struct timeouts_it _it = TIMEOUTS_IT_INITIALIZER((flags));      \
	while (((var) = timeouts_next((T), &_it)))


/*
 * B O N U S  W H E E L  I N T E R F A C E S
 *
 * I usually use floating point timeouts in all my code, but it's cleaner to
 * separate it to keep the core algorithmic code simple.
 *
 * Using macros instead of static inline routines where <math.h> routines
 * might be used to keep -lm linking optional.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#include <math.h> /* ceil(3) */

#define timeouts_f2i(T, f) \
	((timeout_t)ceil((f) * timeouts_hz((T)))) /* prefer late expiration over early */

#define timeouts_i2f(T, i) \
	((double)(i) / timeouts_hz((T)))

#define timeouts_addf(T, to, timeout) \
	timeouts_add((T), (to), timeouts_f2i((T), (timeout)))

#endif /* TIMEOUT_H */
