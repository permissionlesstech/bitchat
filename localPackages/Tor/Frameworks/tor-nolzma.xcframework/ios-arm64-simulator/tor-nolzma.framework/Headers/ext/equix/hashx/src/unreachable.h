#ifndef UNREACHABLE
#ifdef __GNUC__
#define UNREACHABLE __builtin_unreachable()
#elif _MSC_VER
#define UNREACHABLE __assume(0)
#else
#define UNREACHABLE
#endif
#endif
