#ifndef FORCE_INLINE
#if defined(_MSC_VER)
#define FORCE_INLINE __inline
#elif defined(__GNUC__) || defined(__clang__)
#define FORCE_INLINE __inline__
#else
#define FORCE_INLINE
#endif
#endif
