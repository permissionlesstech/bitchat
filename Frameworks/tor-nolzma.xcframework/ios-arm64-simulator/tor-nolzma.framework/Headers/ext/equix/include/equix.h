/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef EQUIX_H
#define EQUIX_H

#include <stdint.h>
#include <stddef.h>

/*
 * The solver will return at most this many solutions.
 */
#define EQUIX_MAX_SOLS 8

/*
 * The number of indices.
 */
#define EQUIX_NUM_IDX 8

/*
 * 16-bit index.
 */
typedef uint16_t equix_idx;

/*
 *  The solution.
 */
typedef struct equix_solution {
    equix_idx idx[EQUIX_NUM_IDX];
} equix_solution;

/*
 * Extra informational flags returned by the solver
 */
typedef enum equix_solution_flags {
    EQUIX_SOLVER_DID_USE_COMPILER = (1 << 0),
} equix_solution_flags;

/*
 * Fixed size buffer containing up to EQUIX_MAX_SOLS solutions.
 */
typedef struct equix_solutions_buffer {
    unsigned count;
    equix_solution_flags flags;
    equix_solution sols[EQUIX_MAX_SOLS];
} equix_solutions_buffer;

/*
 * Result type for solve and verify operations
 */
typedef enum equix_result {
    EQUIX_OK,               /* Solution is valid */
    EQUIX_FAIL_CHALLENGE,   /* The challenge is invalid (the internal hash
                               function doesn't pass validation). */
    EQUIX_FAIL_ORDER,       /* Indices are not in the correct order. */
    EQUIX_FAIL_PARTIAL_SUM, /* The partial sums of the hash values don't
                               have the required number of trailing zeroes. */
    EQUIX_FAIL_FINAL_SUM,   /* The hash values don't sum to zero. */
    EQUIX_FAIL_COMPILE,     /* Can't compile, and no fallback is enabled */
    EQUIX_FAIL_NO_SOLVER,   /* Solve requested on a context with no solver */
    EQUIX_FAIL_INTERNAL,    /* Internal error (bug) */
} equix_result;

/*
 * Opaque struct that holds the Equi-X context
 */
typedef struct equix_ctx equix_ctx;

/*
 * Flags for context creation
 */
typedef enum equix_ctx_flags {
    EQUIX_CTX_VERIFY = 0,       /* Context for verification */
    EQUIX_CTX_SOLVE = 1,        /* Context for solving */
    EQUIX_CTX_MUST_COMPILE = 2, /* Must compile internal hash function */
    EQUIX_CTX_TRY_COMPILE = 4,  /* Compile if possible */
    EQUIX_CTX_HUGEPAGES = 8,    /* Allocate solver memory using HugePages */
} equix_ctx_flags;

#if defined(_WIN32) || defined(__CYGWIN__)
#define EQUIX_WIN
#endif

/* Shared/static library definitions */
#ifdef EQUIX_WIN
    #ifdef EQUIX_SHARED
        #define EQUIX_API __declspec(dllexport)
    #elif !defined(EQUIX_STATIC)
        #define EQUIX_API __declspec(dllimport)
    #else
        #define EQUIX_API
    #endif
    #define EQUIX_PRIVATE
#else
    #ifdef EQUIX_SHARED
        #define EQUIX_API __attribute__ ((visibility ("default")))
    #else
        #define EQUIX_API __attribute__ ((visibility ("hidden")))
    #endif
    #define EQUIX_PRIVATE __attribute__ ((visibility ("hidden")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Allocate an Equi-X context.
 *
 * @param flags is the type of context to be created
 *
 * @return pointer to a newly created context. Returns NULL on memory
 *         allocation failure.
 */
EQUIX_API equix_ctx* equix_alloc(equix_ctx_flags flags);

/*
* Free an Equi-X a context.
*
* @param ctx is a pointer to the context
*/
EQUIX_API void equix_free(equix_ctx* ctx);

/*
 * Find Equi-X solutions for the given challenge.
 *
 * @param ctx             pointer to an Equi-X context
 * @param challenge       pointer to the challenge data
 * @param challenge_size  size of the challenge
 * @param output          pointer to the output array where solutions will be
 *                        stored
 *
 * @return On success, returns EQUIX_OK and sets output->count to the number
 *         of solutions found, with the solutions themselves written to the
 *         output buffer. If the challenge is unusable, returns
 *         EQUIX_FAIL_CHALLENGE. If the EQUIX_CTX_MUST_COMPILE flag is in use
 *         and the compiler fails, this can return EQUIX_FAIL_COMPILE.
 */
EQUIX_API equix_result equix_solve(
    equix_ctx* ctx,
    const void* challenge,
    size_t challenge_size,
    equix_solutions_buffer *output);

/*
 * Verify an Equi-X solution.
 *
 * @param ctx             pointer to an Equi-X context
 * @param challenge       pointer to the challenge data
 * @param challenge_size  size of the challenge
 * @param solution        pointer to the solution to be verified
 *
 * @return Verification result. This can return EQUIX_OK or any of the
 *         EQUIX_FAIL_* error codes.
 */
EQUIX_API equix_result equix_verify(
    equix_ctx* ctx,
    const void* challenge,
    size_t challenge_size,
    const equix_solution* solution);

#ifdef __cplusplus
}
#endif

#endif
