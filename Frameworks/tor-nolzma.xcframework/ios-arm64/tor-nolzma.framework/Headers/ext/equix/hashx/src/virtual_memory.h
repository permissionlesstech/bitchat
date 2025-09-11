/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef VIRTUAL_MEMORY_H
#define VIRTUAL_MEMORY_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <hashx.h>

#define ALIGN_SIZE(pos, align) ((((pos) - 1) / (align) + 1) * (align))

HASHX_PRIVATE void* hashx_vm_alloc(size_t size);
HASHX_PRIVATE bool hashx_vm_rw(void* ptr, size_t size);
HASHX_PRIVATE bool hashx_vm_rx(void* ptr, size_t size);
HASHX_PRIVATE void hashx_vm_free(void* ptr, size_t size);

#ifdef EQUIX_SUPPORT_HUGEPAGES
HASHX_PRIVATE void* hashx_vm_alloc_huge(size_t size);
#endif

#endif
