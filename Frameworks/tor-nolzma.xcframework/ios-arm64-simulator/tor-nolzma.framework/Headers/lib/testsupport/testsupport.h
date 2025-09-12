/* Copyright (c) 2013-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file testsupport.h
 *
 * \brief Macros to implement mocking and selective exposure for the test code.
 *
 * Each Tor source file is built twice: once with TOR_UNIT_TESTS defined, and
 * once with it undefined.  The only difference between these configurations
 * should be that when building for the tests, more functions are exposed as
 * non-static, and a number of functions are declared as mockable.
 **/

#ifndef TOR_TESTSUPPORT_H
#define TOR_TESTSUPPORT_H

/** The "STATIC" macro marks a function or variable that is static when
 * building Tor for production, but non-static when building the unit
 * tests.
 *
 * For example, a function declared as:
 *
 *     STATIC int internal_function(void);
 *
 * should be only visible for the file on which it is declared, and in the
 * unit tests.
 */
#ifdef TOR_UNIT_TESTS
#define STATIC
#else /* !defined(TOR_UNIT_TESTS) */
#define STATIC static
#endif /* defined(TOR_UNIT_TESTS) */

/** The "EXTERN" macro is used along with "STATIC" for variables declarations:
 * it expands to an extern declaration when Tor building unit tests, and to
 * nothing otherwise.
 *
 * For example, to declare a variable as visible only visible in one
 * file and in the unit tests, you would put this in the header:
 *
 *     EXTERN(int, local_variable)
 *
 * and this in the source:
 *
 *     STATIC int local_variable;
 */
#ifdef TOR_UNIT_TESTS
#define EXTERN(type, name) extern type name;
#else
#define EXTERN(type, name)
#endif

/** Quick and dirty macros to implement test mocking.
 *
 * To use them, suppose that you have a function you'd like to mock
 * with the signature "void writebuf(size_t n, char *buf)".  You can then
 * declare the function as:
 *
 *     MOCK_DECL(void, writebuf, (size_t n, char *buf));
 *
 * and implement it as:
 *
 *     MOCK_IMPL(void,
 *     writebuf,(size_t n, char *buf))
 *     {
 *          ...
 *     }
 *
 * For the non-testing build, this will expand simply into:
 *
 *     void writebuf(size_t n, char *buf);
 *     void
 *     writebuf(size_t n, char *buf)
 *     {
 *         ...
 *     }
 *
 * But for the testing case, it will expand into:
 *
 *     void writebuf__real(size_t n, char *buf);
 *     extern void (*writebuf)(size_t n, char *buf);
 *
 *     void (*writebuf)(size_t n, char *buf) = writebuf__real;
 *     void
 *     writebuf__real(size_t n, char *buf)
 *     {
 *         ...
 *     }
 *
 * This is not a great mocking system!  It is deliberately "the simplest
 * thing that could work", and pays for its simplicity in its lack of
 * features, and in its uglification of the Tor code.  Replacing it with
 * something clever would be a fine thing.
 *
 * @{ */
#ifdef TOR_UNIT_TESTS
/** Declare a mocked function. For use in headers. */
#define MOCK_DECL(rv, funcname, arglist)     \
  rv funcname ##__real arglist;              \
  extern rv(*funcname) arglist
/** Define the implementation of a mocked function. */
#define MOCK_IMPL(rv, funcname, arglist)     \
  rv(*funcname) arglist = funcname ##__real; \
  rv funcname ##__real arglist
/** As MOCK_DECL(), but allow attributes. */
#define MOCK_DECL_ATTR(rv, funcname, arglist, attr) \
  rv funcname ##__real arglist attr;                \
  extern rv(*funcname) arglist
/**
 * Replace <b>func</b> (a mockable function) with a replacement function.
 *
 * Only usable when Tor has been built for unit tests. */
#define MOCK(func, replacement)                 \
  do {                                          \
    (func) = (replacement);                     \
  } while (0)
/** Replace <b>func</b> (a mockable function) with its original value.
 *
 * Only usable when Tor has been built for unit tests. */
#define UNMOCK(func)                            \
  do {                                          \
    func = func ##__real;                       \
  } while (0)
#else /* !defined(TOR_UNIT_TESTS) */
/** Declare a mocked function. For use in headers. */
#define MOCK_DECL(rv, funcname, arglist) \
  rv funcname arglist
/** As MOCK_DECL(), but allow  */
#define MOCK_DECL_ATTR(rv, funcname, arglist, attr)     \
  rv funcname arglist attr
/** Define the implementation of a mocked function. */
#define MOCK_IMPL(rv, funcname, arglist)        \
  rv funcname arglist
#endif /* defined(TOR_UNIT_TESTS) */
/** @} */

#endif /* !defined(TOR_TESTSUPPORT_H) */
