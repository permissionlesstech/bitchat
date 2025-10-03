/* os */
#if defined(_WIN32)	|| defined(_WIN64) || defined(__TOS_WIN__) || defined(__WINDOWS__)
	#define OS_WINDOWS
#elif defined(sun) || defined(__sun) || defined(__SVR4) || defined(__svr4__)
	#define OS_SOLARIS
#else
	#include <sys/param.h> /* need this to define BSD */
	#define OS_NIX
	#if defined(__linux__)
		#define OS_LINUX
	#elif defined(BSD)
		#define OS_BSD
		#if defined(MACOS_X) || (defined(__APPLE__) & defined(__MACH__))
			#define OS_OSX
		#elif defined(macintosh) || defined(Macintosh)
			#define OS_MAC
		#elif defined(OpenBSD)
			#define OS_OPENBSD
		#endif
	#endif
#endif


/* compiler */
#if defined(_MSC_VER)
	#define COMPILER_MSVC
#endif
#if defined(__ICC)
	#define COMPILER_INTEL
#endif
#if defined(__GNUC__)
	#if (__GNUC__ >= 3)
		#define COMPILER_GCC ((__GNUC__ * 10000) + (__GNUC_MINOR__ * 100) + (__GNUC_PATCHLEVEL__))
	#else
		#define COMPILER_GCC ((__GNUC__ * 10000) + (__GNUC_MINOR__ * 100)                        )
	#endif
#endif
#if defined(__PATHCC__)
	#define COMPILER_PATHCC
#endif
#if defined(__clang__)
	#define COMPILER_CLANG ((__clang_major__ * 10000) + (__clang_minor__ * 100) + (__clang_patchlevel__))
#endif



/* cpu */
#if defined(__amd64__) || defined(__amd64) || defined(__x86_64__ ) || defined(_M_X64)
	#define CPU_X86_64
#elif defined(__i586__) || defined(__i686__) || (defined(_M_IX86) && (_M_IX86 >= 500))
	#define CPU_X86 500
#elif defined(__i486__) || (defined(_M_IX86) && (_M_IX86 >= 400))
	#define CPU_X86 400
#elif defined(__i386__) || (defined(_M_IX86) && (_M_IX86 >= 300)) || defined(__X86__) || defined(_X86_) || defined(__I86__)
	#define CPU_X86 300
#elif defined(__ia64__) || defined(_IA64) || defined(__IA64__) || defined(_M_IA64) || defined(__ia64)
	#define CPU_IA64
#endif

#if defined(__sparc__) || defined(__sparc) || defined(__sparcv9)
	#define CPU_SPARC
	#if defined(__sparcv9)
		#define CPU_SPARC64
	#endif
#endif

#if defined(powerpc) || defined(__PPC__) || defined(__ppc__) || defined(_ARCH_PPC) || defined(__powerpc__) || defined(__powerpc) || defined(POWERPC) || defined(_M_PPC)
	#define CPU_PPC
	#if defined(_ARCH_PWR7)
		#define CPU_POWER7
	#elif defined(__64BIT__)
		#define CPU_PPC64
	#else
		#define CPU_PPC32
	#endif
#endif

#if defined(__hppa__) || defined(__hppa)
	#define CPU_HPPA
#endif

#if defined(__alpha__) || defined(__alpha) || defined(_M_ALPHA)
	#define CPU_ALPHA
#endif

/* 64 bit cpu */
#if defined(CPU_X86_64) || defined(CPU_IA64) || defined(CPU_SPARC64) || defined(__64BIT__) || defined(__LP64__) || defined(_LP64) || (defined(_MIPS_SZLONG) && (_MIPS_SZLONG == 64))
	#define CPU_64BITS
#endif

#if defined(COMPILER_MSVC)
	typedef signed char int8_t;
	typedef unsigned char uint8_t;
	typedef signed short int16_t;
	typedef unsigned short uint16_t;
	typedef signed int int32_t;
	typedef unsigned int uint32_t;
	typedef signed __int64 int64_t;
	typedef unsigned __int64 uint64_t;
#else
	#include <stdint.h>
#endif

