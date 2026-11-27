/* Crypto and OS odds and ends Goose has no library for: SHA-256, HMAC-SHA256,
 * OS randomness, Argon2id password hashing (vendored reference implementation)
 * and handing a message to sendmail. */
#define _GNU_SOURCE
#include "goose.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>

#include <sys/mman.h>

#include "argon2.h"
#include "encoding.h"

typedef struct { const uint8_t *data; int64_t len; } ib_slice;
typedef struct { uint8_t *data; int64_t len; } ib_mslice;

/* ---- SHA-256 (FIPS 180-4) ---------------------------------------------- */

typedef struct { uint32_t h[8]; uint64_t n; uint8_t buf[64]; size_t blen; } sha256_ctx;

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(sha256_ctx *c, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3], e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d;
    c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void sha256_init(sha256_ctx *c) {
    static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    memcpy(c->h, iv, sizeof iv);
    c->n = 0; c->blen = 0;
}

static void sha256_update(sha256_ctx *c, const uint8_t *p, size_t n) {
    c->n += n;
    while (n) {
        size_t k = 64 - c->blen < n ? 64 - c->blen : n;
        memcpy(c->buf + c->blen, p, k);
        c->blen += k; p += k; n -= k;
        if (c->blen == 64) { sha256_block(c, c->buf); c->blen = 0; }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->n * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    uint8_t z = 0;
    while (c->blen != 56) sha256_update(c, &z, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, len, 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(c->h[i] >> 24); out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->h[i] >> 8); out[4 * i + 3] = (uint8_t)c->h[i];
    }
}

void ib_sha256(ib_slice data, uint8_t *out) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, data.data, (size_t)data.len);
    sha256_final(&c, out);
}

void ib_hmac_sha256(ib_slice key, ib_slice data, uint8_t *out) {
    uint8_t k[64] = {0}, ipad[64], opad[64], inner[32];
    if (key.len > 64) ib_sha256(key, k);
    else memcpy(k, key.data, (size_t)key.len);
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    sha256_ctx c;
    sha256_init(&c); sha256_update(&c, ipad, 64); sha256_update(&c, data.data, (size_t)data.len); sha256_final(&c, inner);
    sha256_init(&c); sha256_update(&c, opad, 64); sha256_update(&c, inner, 32); sha256_final(&c, out);
}

/* Constant-time equality, for MACs and token hashes. */
bool ib_ct_equal(ib_slice a, ib_slice b) {
    if (a.len != b.len) return false;
    uint8_t d = 0;
    for (int64_t i = 0; i < a.len; i++) d |= a.data[i] ^ b.data[i];
    return d == 0;
}

/* Fills `out` from the OS CSPRNG. */
void ib_random(ib_mslice out) {
    int64_t off = 0;
    while (off < out.len) {
        ssize_t n = getrandom(out.data + off, (size_t)(out.len - off), 0);
        if (n > 0) off += n;
    }
}

/* ---- Argon2id ------------------------------------------------------------
 * Same parameters TrailBase uses (m=19456 KiB, t=2, p=1), so hashes imported
 * from a TrailBase database verify unchanged. */

#define A2_T 2
#define A2_M 19456
#define A2_P 1

/* Argon2's 19 MiB working buffer comes straight from mmap and goes straight
 * back: through malloc it would stay in that thread's arena after the hash,
 * pinning ~19 MiB of RSS per worker that has ever checked a password. */
static int a2_alloc(uint8_t **memory, size_t bytes) {
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return ARGON2_MEMORY_ALLOCATION_ERROR;
    *memory = p;
    return ARGON2_OK;
}
static void a2_free(uint8_t *memory, size_t bytes) { munmap(memory, bytes); }

bool ib_argon2_hash(ib_slice pw, gs_rref out) {
    uint8_t salt[16], hash[32];
    ib_random((ib_mslice){ salt, 16 });
    argon2_context ctx = {
        .out = hash, .outlen = sizeof hash,
        .pwd = (uint8_t *)pw.data, .pwdlen = (uint32_t)pw.len,
        .salt = salt, .saltlen = sizeof salt,
        .t_cost = A2_T, .m_cost = A2_M, .lanes = A2_P, .threads = A2_P,
        .version = ARGON2_VERSION_13,
        .allocate_cbk = a2_alloc, .free_cbk = a2_free,
        .flags = ARGON2_DEFAULT_FLAGS,
    };
    if (argon2_ctx(&ctx, Argon2_id) != ARGON2_OK) return false;
    char enc[128];
    if (encode_string(enc, sizeof enc, &ctx, Argon2_id) != ARGON2_OK) return false;
    gs_bld_append(out, enc, (int64_t)strlen(enc));
    return true;
}

/* argon2_verify(), but with the mmap allocator. */
bool ib_argon2_verify(ib_slice encoded, ib_slice pw) {
    char enc[256];
    if (encoded.len <= 0 || encoded.len >= (int64_t)sizeof enc) return false;
    memcpy(enc, encoded.data, (size_t)encoded.len);
    enc[encoded.len] = 0;
    argon2_type t;
    if (strncmp(enc, "$argon2id$", 10) == 0) t = Argon2_id;
    else if (strncmp(enc, "$argon2i$", 9) == 0) t = Argon2_i;
    else if (strncmp(enc, "$argon2d$", 9) == 0) t = Argon2_d;
    else return false;
    uint8_t salt[256], desired[256], out[256];
    argon2_context ctx = { .salt = salt, .saltlen = sizeof salt, .out = desired, .outlen = sizeof desired,
                           .pwd = (uint8_t *)pw.data, .pwdlen = (uint32_t)pw.len };
    if (decode_string(&ctx, enc, t) != ARGON2_OK) return false;
    if (ctx.outlen > sizeof out) return false;
    ctx.out = out;
    ctx.allocate_cbk = a2_alloc;
    ctx.free_cbk = a2_free;
    return argon2_verify_ctx(&ctx, (const char *)desired, t) == ARGON2_OK;
}

/* ---- Mail ----------------------------------------------------------------
 * Pipes a complete RFC 5322 message (headers, blank line, body) to
 * `<cmd> -t -i`, the sendmail interface msmtp, postfix and exim all provide. */
bool ib_sendmail(ib_slice cmd, ib_slice msg) {
    char c[600];
    if (cmd.len <= 0 || cmd.len > 512) return false;
    memcpy(c, cmd.data, (size_t)cmd.len);
    strcpy(c + cmd.len, " -t -i");
    FILE *f = popen(c, "w");
    if (!f) return false;
    size_t w = fwrite(msg.data, 1, (size_t)msg.len, f);
    int rc = pclose(f);
    return w == (size_t)msg.len && rc == 0;
}

/* Makes a secrets file readable by its owner only. */
#include <sys/stat.h>
void ib_chmod_private(ib_slice path) {
    char p[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof p) return;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    chmod(p, 0600);
}
