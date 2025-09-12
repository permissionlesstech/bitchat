/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

/*
 * HashX is an algorithm designed for client puzzles and proof-of-work schemes.
 * While traditional cryptographic hash functions use a fixed one-way
 * compression function, each HashX instance represents a unique pseudorandomly
 * generated one-way function.
 *
 * Example of usage:
 *
    #include <hashx.h>
    #include <stdio.h>

    int main() {
        char seed[] = "this is a seed that will generate a hash function";
        char hash[HASHX_SIZE];
        hashx_ctx* ctx = hashx_alloc(HASHX_TRY_COMPILE);
        if (ctx == NULL)
            return 1;
        if (hashx_make(ctx, seed, sizeof(seed)) != EQUIX_OK)
            return 1;
        if (hashx_exec(ctx, 123456789, hash) != EQUIX_OK)
            return 1;
        hashx_free(ctx);
        for (unsigned i = 0; i < HASHX_SIZE; ++i)
            printf("%02x", hash[i] & 0xff);
        printf("\n");
        return 0;
    }
 *
 */

#ifndef HASHX_H
#define HASHX_H

#include <stdint.h>
#include <stddef.h>

/*
 * Input of the hash function.
 *
 * Counter mode (default): a 64-bit unsigned integer
 * Block mode: pointer to a buffer and the number of bytes to be hashed
*/
#ifndef HASHX_BLOCK_MODE
#define HASHX_INPUT uint64_t input
#else
#define HASHX_INPUT const void* input, size_t size
#endif

/* The default (and maximum) hash size is 32 bytes */
#ifndef HASHX_SIZE
#define HASHX_SIZE 32
#endif

/* Opaque struct representing a HashX instance */
typedef struct hashx_ctx hashx_ctx;

/* Type of hash context / type of compiled function */
typedef enum hashx_type {
    HASHX_TYPE_INTERPRETED = 1, /* Only the interpreted implementation */
    HASHX_TYPE_COMPILED,        /* Require the compiler, fail if unavailable */
    HASHX_TRY_COMPILE,          /* (hashx_alloc) Try compiler, don't require */
} hashx_type;

/* Result code for hashx_make and hashx_exec */
typedef enum hashx_result {
    HASHX_OK = 0,
    HASHX_FAIL_UNPREPARED, /* Trying to run an unmade hash funciton */
    HASHX_FAIL_UNDEFINED,  /* Unrecognized hashx_type enum value */
    HASHX_FAIL_SEED,       /* Can't construct a hash function from this seed */
    HASHX_FAIL_COMPILE,    /* Can't compile, and no fallback is enabled. */
} hashx_result;

#if defined(_WIN32) || defined(__CYGWIN__)
#define HASHX_WIN
#endif

/* Shared/static library definitions */
#ifdef HASHX_WIN
    #ifdef HASHX_SHARED
        #define HASHX_API __declspec(dllexport)
    #elif !defined(HASHX_STATIC)
        #define HASHX_API __declspec(dllimport)
    #else
        #define HASHX_API
    #endif
    #define HASHX_PRIVATE
#else
    #ifdef HASHX_SHARED
        #define HASHX_API __attribute__ ((visibility ("default")))
    #else
        #define HASHX_API __attribute__ ((visibility ("hidden")))
    #endif
    #define HASHX_PRIVATE __attribute__ ((visibility ("hidden")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Allocate a HashX instance.
 *
 * @param type is the type of instance to be created.
 *
 * @return pointer to a new HashX instance. Returns NULL on memory allocation
 *         failures only. Other failures are reported in hashx_make.
 */
HASHX_API hashx_ctx* hashx_alloc(hashx_type type);

/*
 * Create a new HashX function from a variable-length seed value.
 *
 * The seed value will be hashed internally in order to initialize the state
 * of the HashX program generator and create a new unique hash function.
 *
 * @param ctx is pointer to a HashX instance.
 * @param seed is a pointer to the seed value.
 * @param size is the size of the seed.
 *
 * @return HASHX_OK on success, HASHX_FAIL_SEED if the specific seed is
 *         not associated with a valid hash program, and HASHX_FAIL_COMPILE
 *         if the compiler failed for OS-specific reasons and the interpreter
 *         fallback was disabled by allocating the context with
 *         HASHX_TYPE_COMPILED rather than HASHX_TRY_COMPILE.
 */
HASHX_API hashx_result hashx_make(hashx_ctx* ctx,
                                  const void* seed, size_t size);

/*
 * Asks the specific implementation of a function created with hashx_make.
 *
 * This will equal the parameter to hashx_alloc() if a specific type was
 * chosen there, but a context allocated with HASHX_TRY_COMPILE will allow
 * the implementation to vary dynamically during hashx_make.
 *
 * @param ctx is pointer to a HashX instance.
 * @param type_out is a pointer to which, on success, we write
 *                 a HASHX_TYPE_* value.
 *
 * @return HASHX_OK on success, or HASHX_FAIL_UNPREPARED if hashx_make has not
 *         been invoked successfully on this context.
*/
HASHX_API hashx_result hashx_query_type(hashx_ctx* ctx, hashx_type *type_out);

/*
 * Execute the HashX function.
 *
 * @param ctx is pointer to a HashX instance. A HashX function must have
 *        been previously created by invoking hashx_make successfully.
 * @param HASHX_INPUT is the input to be hashed (see definition above).
 * @param output is a pointer to the result buffer. HASHX_SIZE bytes will be
 *        written.
 *
 * @return HASHX_OK on success, or HASHX_FAIL_UNPREPARED if hashx_make has not
 *         been invoked successfully on this context.
 */
HASHX_API hashx_result hashx_exec(const hashx_ctx* ctx,
                                  HASHX_INPUT, void* output);

/*
 * Free a HashX instance.
 *
 * Has no effect if ctx is NULL.
 *
 * @param ctx is pointer to a HashX instance.
*/
HASHX_API void hashx_free(hashx_ctx* ctx);

#ifdef HASHX_RNG_CALLBACK
/*
 * Set a callback for inspecting or modifying the HashX random number stream.
 *
 * The callback and its user pointer are associated with the provided context
 * even if it's re-used for another hash program. A callback value of NULL
 * disables the callback.
 *
 * @param ctx is pointer to a HashX instance.
 * @param callback is invoked after each new 64-bit pseudorandom value
 *        is generated in a buffer. The callback may record it and/or replace
 *        it. A NULL pointer here disables the callback.
 * @param user_data is an opaque parameter given to the callback
 */
HASHX_API void hashx_rng_callback(hashx_ctx* ctx,
                                  void (*callback)(uint64_t*, void*),
                                  void* user_data);
#endif

#ifdef __cplusplus
}
#endif

#endif
