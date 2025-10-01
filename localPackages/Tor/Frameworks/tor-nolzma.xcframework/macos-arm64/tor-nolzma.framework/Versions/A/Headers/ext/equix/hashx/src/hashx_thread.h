/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef HASHX_THREAD_H
#define HASHX_THREAD_H

#include <hashx.h>

#ifdef HASHX_WIN
#include <Windows.h>
typedef HANDLE hashx_thread;
typedef DWORD hashx_thread_retval;
#define HASHX_THREAD_SUCCESS 0
#else
#include <pthread.h>
typedef pthread_t hashx_thread;
typedef void* hashx_thread_retval;
#define HASHX_THREAD_SUCCESS NULL
#endif

typedef hashx_thread_retval hashx_thread_func(void* args);

hashx_thread hashx_thread_create(hashx_thread_func* func, void* args);

void hashx_thread_join(hashx_thread thread);

#endif
