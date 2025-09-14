#include "ed25519-donna-portable-identify.h"

/* ticks - not tested on anything other than x86 */
static uint64_t
get_ticks(void) {
#if defined(CPU_X86) || defined(CPU_X86_64)
	#if defined(COMPILER_INTEL)
		return _rdtsc();
	#elif defined(COMPILER_MSVC)
		return __rdtsc();
	#elif defined(COMPILER_GCC)
		uint32_t lo, hi;
		__asm__ __volatile__("rdtsc" : "=a" (lo), "=d" (hi));
		return ((uint64_t)lo | ((uint64_t)hi << 32));
	#else
		#error need rdtsc for this compiler
	#endif
#elif defined(OS_SOLARIS)
	return (uint64_t)gethrtime();
#elif defined(CPU_SPARC) && !defined(OS_OPENBSD)
	uint64_t t;
	__asm__ __volatile__("rd %%tick, %0" : "=r" (t));
	return t;
#elif defined(CPU_PPC)
	uint32_t lo = 0, hi = 0;
	__asm__ __volatile__("mftbu %0; mftb %1" : "=r" (hi), "=r" (lo));
	return ((uint64_t)lo | ((uint64_t)hi << 32));
#elif defined(CPU_IA64)
	uint64_t t;
	__asm__ __volatile__("mov %0=ar.itc" : "=r" (t));
	return t;
#elif defined(OS_NIX)
	timeval t2;
	gettimeofday(&t2, NULL);
	t = ((uint64_t)t2.tv_usec << 32) | (uint64_t)t2.tv_sec;
	return t;
#else
	#error need ticks for this platform
#endif
}

#define timeit(x,minvar)         \
	ticks = get_ticks();         \
 	x;                           \
	ticks = get_ticks() - ticks; \
	if (ticks < minvar)          \
		minvar = ticks;

#define maxticks 0xffffffffffffffffull

