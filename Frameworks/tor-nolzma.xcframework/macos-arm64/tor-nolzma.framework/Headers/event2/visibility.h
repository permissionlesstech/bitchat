/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/*
 * Copyright (c) 2007-2012 Niels Provos and Nick Mathewson
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#ifndef EVENT2_VISIBILITY_H_INCLUDED_
#define EVENT2_VISIBILITY_H_INCLUDED_

#include <event2/event-config.h>

#if defined(event_shared_EXPORTS) || \
    defined(event_extra_shared_EXPORTS) || \
    defined(event_core_shared_EXPORTS) || \
    defined(event_pthreads_shared_EXPORTS) || \
    defined(event_openssl_shared_EXPORTS)

# if defined (__SUNPRO_C) && (__SUNPRO_C >= 0x550)
#  define EVENT2_EXPORT_SYMBOL __global
# elif defined __GNUC__
#  define EVENT2_EXPORT_SYMBOL __attribute__ ((visibility("default")))
# elif defined(_MSC_VER)
#  define EVENT2_EXPORT_SYMBOL __declspec(dllexport)
# else
#  define EVENT2_EXPORT_SYMBOL /* unknown compiler */
# endif

#else /* event_*_EXPORTS */

# define EVENT2_EXPORT_SYMBOL

#endif /* event_*_EXPORTS */

/** We need to dllimport event_debug_logging_mask_ into event_extra */
#if defined(_MSC_VER)
# if defined(event_core_shared_EXPORTS) /** from core export */
#  define EVENT2_CORE_EXPORT_SYMBOL __declspec(dllexport)
# elif defined(event_extra_shared_EXPORTS) || /** from extra import */ \
       defined(EVENT_VISIBILITY_WANT_DLLIMPORT)
#  define EVENT2_CORE_EXPORT_SYMBOL __declspec(dllimport)
# endif
#endif /* _MSC_VER */
#if !defined(EVENT2_CORE_EXPORT_SYMBOL)
# define EVENT2_CORE_EXPORT_SYMBOL EVENT2_EXPORT_SYMBOL
#endif

#endif /* EVENT2_VISIBILITY_H_INCLUDED_ */
