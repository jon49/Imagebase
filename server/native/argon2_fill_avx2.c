/* The AVX2 build of Argon2's block fill; argon2_fill.c calls it only on
 * CPUs that support AVX2. The pragma also defines __AVX2__, which selects
 * opt.c's AVX2 code paths. */
#if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__)
#pragma GCC target("avx2")
#define fill_segment ib_argon2_fill_segment_avx2
#include "argon2/opt.c"
#endif
