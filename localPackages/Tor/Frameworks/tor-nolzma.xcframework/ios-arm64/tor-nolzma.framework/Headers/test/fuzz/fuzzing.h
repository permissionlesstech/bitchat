/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */
#ifndef FUZZING_H
#define FUZZING_H

int fuzz_init(void);
int fuzz_cleanup(void);
int fuzz_main(const uint8_t *data, size_t sz);

void disable_signature_checking(void);

#endif /* !defined(FUZZING_H) */

