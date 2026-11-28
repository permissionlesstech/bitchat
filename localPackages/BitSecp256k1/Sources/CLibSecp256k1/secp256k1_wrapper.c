/*
 * Local wrapper around upstream libsecp256k1's single-translation-unit entry point.
 *
 * Xcode's project-level GCC_WARN_64_TO_32_BIT_CONVERSION (-Wshorten-64-to-32)
 * propagates to local Swift packages, triggering benign narrowing warnings in
 * upstream libsecp256k1 (which intentionally truncates verified values and
 * builds without -Wshorten-64-to-32). Suppressing the diagnostic here keeps
 * upstream sources verbatim and avoids SwiftPM .unsafeFlags in Package.swift.
 */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#endif

#include "src/secp256k1.c"

#if defined(__clang__)
#pragma clang diagnostic pop
#endif
