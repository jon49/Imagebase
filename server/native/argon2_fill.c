/* Argon2's block-fill function, picked at runtime on x86-64: an AVX2 build
 * (about twice as fast) where the CPU has it, the SSE2 one otherwise. Other
 * architectures get the portable reference implementation. */
#if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__)

#define fill_segment ib_argon2_fill_segment_sse2
#include "argon2/opt.c"
#undef fill_segment

void ib_argon2_fill_segment_avx2(const argon2_instance_t *instance, argon2_position_t position);

void fill_segment(const argon2_instance_t *instance, argon2_position_t position) {
    static int avx2 = -1;
    if (avx2 < 0) avx2 = __builtin_cpu_supports("avx2") ? 1 : 0;
    if (avx2) ib_argon2_fill_segment_avx2(instance, position);
    else ib_argon2_fill_segment_sse2(instance, position);
}

#elif defined(__x86_64__)
#include "argon2/opt.c"
#else
#include "argon2/ref.c"
#endif
