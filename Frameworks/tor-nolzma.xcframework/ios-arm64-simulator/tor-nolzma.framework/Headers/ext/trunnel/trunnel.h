/* trunnel.h -- copied from Trunnel v1.5.3
 * https://gitweb.torproject.org/trunnel.git
 * You probably shouldn't edit this file.
 */
/* trunnel.h -- Public declarations for trunnel, to be included
 * in trunnel header files.

 * Copyright 2014-2019, The Tor Project, Inc.
 * See license at the end of this file for copying information.
 */

#ifndef TRUNNEL_H_INCLUDED_
#define TRUNNEL_H_INCLUDED_

#include <sys/types.h>

/** Macro to declare a variable-length dynamically allocated array.  Trunnel
 * uses these to store all variable-length arrays. */
#define TRUNNEL_DYNARRAY_HEAD(name, elttype)       \
  struct name {                                    \
    size_t n_;                                     \
    size_t allocated_;                             \
    elttype *elts_;                                \
  }

/** Initializer for a dynamic array of a given element type. */
#define TRUNNEL_DYNARRAY_INIT(elttype) { 0, 0, (elttype*)NULL }

/** Typedef used for storing variable-length arrays of char. */
typedef TRUNNEL_DYNARRAY_HEAD(trunnel_string_st, char) trunnel_string_t;

#endif

/*
Copyright 2014  The Tor Project, Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

    * Neither the names of the copyright owners nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
