/* HTTP/1.1 front end for the ImageBase server.
 *
 * Goose has no sockets, so this file owns the network: one I/O thread runs an
 * epoll loop that accepts connections, reads and frames requests, and writes
 * responses. Complete requests go onto a queue that the Goose worker threads
 * drain through ib_http_next(); a worker answers with ib_http_respond(), which
 * hands the bytes back to the I/O thread. Everything the application does
 * (routing, auth, SQL, JSON) happens in Goose; this layer only moves bytes.
 *
 * Supported: keep-alive, pipelining (one request in flight per connection),
 * Content-Length bodies, `Expect: 100-continue`. Not supported: chunked request
 * bodies (answered with 411), HTTP/2, TLS (terminate it in a reverse proxy).
 */
#define _GNU_SOURCE
#include "goose.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } ib_slice;

/* Must match `struct ReqMeta` in http.goose (Goose structs are packed). */
#pragma pack(push, 1)
typedef struct {
    int64_t conn, method_len, target_len, headers_len, body_len;
} ib_req_meta;
#pragma pack(pop)

#define MAX_HEADER_BYTES (64 * 1024)
#define MAX_BODY_BYTES   (32 * 1024 * 1024)
#define MAX_SLOTS        256
#define IDLE_TIMEOUT_S   60     /* keep-alive connection with nothing sent */
#define REQUEST_TIMEOUT_S 30    /* a request that started but isn't complete */

enum { C_READING, C_BUSY, C_WRITING };

typedef struct conn {
    int fd;
    uint32_t gen;
    int state;
    bool keep_alive, is_head, dead, sent_continue;
    char *rbuf; size_t rlen, rcap;
    size_t consumed;          /* bytes of rbuf the in-flight request occupies */
    char *wbuf; size_t wlen, woff;
    time_t last;              /* last read or completed write */
} conn;

typedef struct job {
    int64_t conn_id;
    char *data;               /* method|target|headers|body, malloc'd */
    ib_req_meta meta;
} job;

static int g_epfd = -1, g_listen = -1, g_evfd = -1;
static conn **g_conns;        /* indexed by fd */
static int g_conns_cap;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;        /* jobs queued, or stopping */
static pthread_cond_t g_stop_cv = PTHREAD_COND_INITIALIZER;   /* stopping */
static job *g_jobs; static size_t g_jobs_head, g_jobs_len, g_jobs_cap;
static int *g_done; static size_t g_done_len, g_done_cap;   /* fds with a response ready */
static volatile sig_atomic_t g_stop_signal;
static bool g_stopping;
static pthread_t g_io;
static int64_t g_inflight[MAX_SLOTS];                        /* conn id per worker slot, 0 = idle */
static bool g_accept_paused;                                 /* out of fds: retry on the next sweep */

static time_t now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

static int64_t conn_id(conn *c) { return ((int64_t)c->gen << 32) | (uint32_t)c->fd; }

static void on_signal(int sig) {
    (void)sig;
    g_stop_signal = 1;
    uint64_t one = 1;
    ssize_t r = write(g_evfd, &one, sizeof one);
    (void)r;
}

static void ep_set(conn *c, uint32_t events) {
    struct epoll_event ev = { .events = events, .data.fd = c->fd };
    epoll_ctl(g_epfd, EPOLL_CTL_MOD, c->fd, &ev);
}

static void conn_free(conn *c) {
    epoll_ctl(g_epfd, EPOLL_CTL_DEL, c->fd, NULL);
    close(c->fd);
    pthread_mutex_lock(&g_mu);
    if (g_conns[c->fd] == c) g_conns[c->fd] = NULL;
    pthread_mutex_unlock(&g_mu);
    free(c->rbuf);
    free(c->wbuf);
    free(c);
}

static void push_job(job j) {
    if (g_jobs_len == g_jobs_cap) {
        size_t ncap = g_jobs_cap ? g_jobs_cap * 2 : 64;
        job *n = malloc(ncap * sizeof *n);
        for (size_t i = 0; i < g_jobs_len; i++) n[i] = g_jobs[(g_jobs_head + i) % g_jobs_cap];
        free(g_jobs);
        g_jobs = n; g_jobs_head = 0; g_jobs_cap = ncap;
    }
    g_jobs[(g_jobs_head + g_jobs_len) % g_jobs_cap] = j;
    g_jobs_len++;
    pthread_cond_signal(&g_cv);
}

static const char *reason(int s) {
    switch (s) {
    case 100: return "Continue";
    case 200: return "OK"; case 201: return "Created"; case 204: return "No Content";
    case 301: return "Moved Permanently"; case 302: return "Found"; case 303: return "See Other";
    case 304: return "Not Modified";
    case 400: return "Bad Request"; case 401: return "Unauthorized"; case 403: return "Forbidden";
    case 404: return "Not Found"; case 405: return "Method Not Allowed";
    case 411: return "Length Required"; case 413: return "Payload Too Large";
    case 415: return "Unsupported Media Type"; case 422: return "Unprocessable Entity";
    case 429: return "Too Many Requests"; case 431: return "Request Header Fields Too Large";
    case 500: return "Internal Server Error"; case 501: return "Not Implemented";
    case 503: return "Service Unavailable";
    default: return "Status";
    }
}

/* Builds the full response in c->wbuf. Called with g_mu held or from the I/O thread. */
static void set_response(conn *c, int status, const uint8_t *hdrs, int64_t hlen,
                         const uint8_t *body, int64_t blen) {
    char head[256];
    int n = snprintf(head, sizeof head, "HTTP/1.1 %d %s\r\n", status, reason(status));
    char tail[128];
    int m = snprintf(tail, sizeof tail, "content-length: %lld\r\n%s\r\n", (long long)blen,
                     c->keep_alive ? "" : "connection: close\r\n");
    if (c->is_head) blen = 0;       /* content-length above stays the GET's */
    size_t total = (size_t)n + (size_t)hlen + (size_t)m + (size_t)blen;
    free(c->wbuf);
    c->wbuf = malloc(total);
    memcpy(c->wbuf, head, (size_t)n);
    if (hlen) memcpy(c->wbuf + n, hdrs, (size_t)hlen);
    memcpy(c->wbuf + n + hlen, tail, (size_t)m);
    if (blen) memcpy(c->wbuf + n + hlen + m, body, (size_t)blen);
    c->wlen = total;
    c->woff = 0;
}

static void respond_now(conn *c, int status, const char *msg) {
    static const char ct[] = "content-type: text/plain; charset=utf-8\r\n";
    c->keep_alive = false;
    set_response(c, status, (const uint8_t *)ct, sizeof ct - 1, (const uint8_t *)msg, (int64_t)strlen(msg));
    c->state = C_WRITING;
}

static const char *find_crlf2(const char *p, size_t n) {
    if (n < 4) return NULL;
    const char *e = memmem(p, n, "\r\n\r\n", 4);
    return e;
}

static bool hdr_eq(const char *name, size_t nlen, const char *want) {
    return strlen(want) == nlen && strncasecmp(name, want, nlen) == 0;
}

static bool value_has_token(const char *v, size_t vlen, const char *tok) {
    size_t tl = strlen(tok);
    for (size_t i = 0; i + tl <= vlen; i++)
        if (strncasecmp(v + i, tok, tl) == 0) return true;
    return false;
}

/* Tries to frame one request at the start of c->rbuf. Returns 1 if one was
 * queued, 0 if more bytes are needed, -1 if the connection got an error
 * response (state is then C_WRITING). */
static int try_frame(conn *c) {
    const char *end = find_crlf2(c->rbuf, c->rlen);
    if (!end) {
        if (c->rlen > MAX_HEADER_BYTES) { respond_now(c, 431, "Request headers too large"); return -1; }
        return 0;
    }
    size_t head_len = (size_t)(end - c->rbuf) + 4;
    const char *p = c->rbuf;
    const char *line_end = memchr(p, '\r', head_len);
    const char *sp1 = memchr(p, ' ', (size_t)(line_end - p));
    const char *sp2 = sp1 ? memchr(sp1 + 1, ' ', (size_t)(line_end - sp1 - 1)) : NULL;
    if (!sp1 || !sp2 || line_end - sp2 < 9 || memcmp(sp2 + 1, "HTTP/1.", 7) != 0) {
        respond_now(c, 400, "Malformed request line");
        return -1;
    }
    bool http10 = sp2[8] == '0';
    size_t method_len = (size_t)(sp1 - p), target_len = (size_t)(sp2 - sp1 - 1);
    const char *hstart = line_end + 2;
    size_t hlen = (size_t)(end + 2 - hstart);   /* each header line keeps its CRLF */

    long long clen = 0;
    bool chunked = false, expect = false;
    bool keep = !http10;
    for (const char *h = hstart; h < end + 2;) {
        const char *eol = memmem(h, (size_t)(end + 2 - h), "\r\n", 2);
        const char *colon = memchr(h, ':', (size_t)(eol - h));
        if (colon) {
            size_t nlen = (size_t)(colon - h);
            const char *v = colon + 1;
            while (v < eol && (*v == ' ' || *v == '\t')) v++;
            size_t vlen = (size_t)(eol - v);
            if (hdr_eq(h, nlen, "content-length")) {
                char tmp[32];
                if (vlen == 0 || vlen >= sizeof tmp) { respond_now(c, 400, "Bad Content-Length"); return -1; }
                memcpy(tmp, v, vlen); tmp[vlen] = 0;
                char *ep; clen = strtoll(tmp, &ep, 10);
                if (*ep || clen < 0) { respond_now(c, 400, "Bad Content-Length"); return -1; }
            } else if (hdr_eq(h, nlen, "transfer-encoding")) {
                chunked = value_has_token(v, vlen, "chunked");
            } else if (hdr_eq(h, nlen, "connection")) {
                if (value_has_token(v, vlen, "close")) keep = false;
                else if (value_has_token(v, vlen, "keep-alive")) keep = true;
            } else if (hdr_eq(h, nlen, "expect")) {
                expect = value_has_token(v, vlen, "100-continue");
            }
        }
        h = eol + 2;
    }
    if (chunked) { respond_now(c, 411, "Chunked request bodies are not supported; send Content-Length"); return -1; }
    if (clen > MAX_BODY_BYTES) { respond_now(c, 413, "Request body too large"); return -1; }
    if (c->rlen < head_len + (size_t)clen) {
        if (expect && !c->sent_continue) {
            static const char cont[] = "HTTP/1.1 100 Continue\r\n\r\n";
            ssize_t r = send(c->fd, cont, sizeof cont - 1, MSG_NOSIGNAL);
            (void)r;
            c->sent_continue = true;
        }
        return 0;
    }

    c->keep_alive = keep;
    c->is_head = method_len == 4 && memcmp(p, "HEAD", 4) == 0;
    c->consumed = head_len + (size_t)clen;
    c->sent_continue = false;
    size_t total = method_len + target_len + hlen + (size_t)clen;
    job j = { .conn_id = conn_id(c), .data = malloc(total ? total : 1) };
    char *o = j.data;
    memcpy(o, p, method_len); o += method_len;
    memcpy(o, sp1 + 1, target_len); o += target_len;
    memcpy(o, hstart, hlen); o += hlen;
    memcpy(o, c->rbuf + head_len, (size_t)clen);
    j.meta = (ib_req_meta){ j.conn_id, (int64_t)method_len, (int64_t)target_len, (int64_t)hlen, clen };
    c->state = C_BUSY;
    ep_set(c, 0);
    pthread_mutex_lock(&g_mu);
    push_job(j);
    pthread_mutex_unlock(&g_mu);
    return 1;
}

static void flush_write(conn *c);

static void after_write(conn *c) {
    free(c->wbuf); c->wbuf = NULL; c->wlen = c->woff = 0;
    c->last = now_s();
    if (!c->keep_alive) { conn_free(c); return; }
    /* Drop the request just answered; pipelined bytes behind it stay. */
    memmove(c->rbuf, c->rbuf + c->consumed, c->rlen - c->consumed);
    c->rlen -= c->consumed;
    c->consumed = 0;
    c->state = C_READING;
    int r = try_frame(c);
    if (r == 0) ep_set(c, EPOLLIN | EPOLLRDHUP);
    else if (r < 0) flush_write(c);
}

static void flush_write(conn *c) {
    while (c->woff < c->wlen) {
        ssize_t n = send(c->fd, c->wbuf + c->woff, c->wlen - c->woff, MSG_NOSIGNAL);
        if (n > 0) { c->woff += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { ep_set(c, EPOLLOUT); return; }
        conn_free(c);
        return;
    }
    after_write(c);
}

static void on_readable(conn *c) {
    for (;;) {
        if (c->rcap - c->rlen < 16384) {
            size_t ncap = c->rcap ? c->rcap * 2 : 16384;
            while (ncap - c->rlen < 16384) ncap *= 2;
            c->rbuf = realloc(c->rbuf, ncap);
            c->rcap = ncap;
        }
        ssize_t n = recv(c->fd, c->rbuf + c->rlen, c->rcap - c->rlen, 0);
        if (n > 0) { c->rlen += (size_t)n; c->last = now_s(); continue; }
        if (n == 0) { conn_free(c); return; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        conn_free(c);
        return;
    }
    int r = try_frame(c);
    if (r < 0) flush_write(c);
}

static void on_accept(void) {
    for (;;) {
        int fd = accept4(g_listen, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EMFILE || errno == ENFILE) {
                /* Level-triggered: stop listening until the sweep frees some. */
                epoll_ctl(g_epfd, EPOLL_CTL_DEL, g_listen, NULL);
                g_accept_paused = true;
            }
            return;
        }
        if (fd >= g_conns_cap) {
            int ncap = g_conns_cap * 2;
            while (fd >= ncap) ncap *= 2;
            pthread_mutex_lock(&g_mu);
            g_conns = realloc(g_conns, (size_t)ncap * sizeof *g_conns);
            memset(g_conns + g_conns_cap, 0, (size_t)(ncap - g_conns_cap) * sizeof *g_conns);
            g_conns_cap = ncap;
            pthread_mutex_unlock(&g_mu);
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        static uint32_t gen_counter = 0;
        conn *c = calloc(1, sizeof *c);
        c->fd = fd;
        c->gen = ++gen_counter;
        c->state = C_READING;
        c->last = now_s();
        pthread_mutex_lock(&g_mu);
        g_conns[fd] = c;
        pthread_mutex_unlock(&g_mu);
        struct epoll_event ev = { .events = EPOLLIN | EPOLLRDHUP, .data.fd = fd };
        epoll_ctl(g_epfd, EPOLL_CTL_ADD, fd, &ev);
    }
}

static void drain_done(void) {
    pthread_mutex_lock(&g_mu);
    size_t n = g_done_len;
    int *fds = malloc((n ? n : 1) * sizeof *fds);
    memcpy(fds, g_done, n * sizeof *fds);
    g_done_len = 0;
    pthread_mutex_unlock(&g_mu);
    for (size_t i = 0; i < n; i++) {
        conn *c = g_conns[fds[i]];
        if (!c || c->state != C_WRITING) continue;
        if (c->dead) { conn_free(c); continue; }
        flush_write(c);
    }
    free(fds);
}

/* Closes connections that have gone quiet while waiting for (more of) a request. */
static void sweep(void) {
    time_t t = now_s();
    for (int fd = 0; fd < g_conns_cap; fd++) {
        conn *c = g_conns[fd];
        if (!c || c->state != C_READING) continue;
        time_t limit = c->rlen ? REQUEST_TIMEOUT_S : IDLE_TIMEOUT_S;
        if (t - c->last >= limit) conn_free(c);
    }
    if (g_accept_paused) {
        struct epoll_event ev = { .events = EPOLLIN, .data.fd = g_listen };
        epoll_ctl(g_epfd, EPOLL_CTL_ADD, g_listen, &ev);
        g_accept_paused = false;
    }
}

static void *io_main(void *arg) {
    (void)arg;
    struct epoll_event evs[256];
    time_t last_sweep = now_s();
    while (!g_stop_signal) {
        int n = epoll_wait(g_epfd, evs, 256, 1000);
        if (now_s() != last_sweep) { last_sweep = now_s(); sweep(); }
        if (n < 0 && errno == EINTR) continue;
        for (int i = 0; i < n; i++) {
            int fd = evs[i].data.fd;
            uint32_t e = evs[i].events;
            if (fd == g_listen) { on_accept(); continue; }
            if (fd == g_evfd) {
                uint64_t v;
                ssize_t r = read(g_evfd, &v, sizeof v);
                (void)r;
                drain_done();
                continue;
            }
            conn *c = fd < g_conns_cap ? g_conns[fd] : NULL;
            if (!c) continue;
            pthread_mutex_lock(&g_mu);
            bool busy = c->state == C_BUSY;
            if (busy && (e & (EPOLLERR | EPOLLHUP | EPOLLRDHUP))) {
                /* A worker owns the request; reap the socket once it answers. */
                c->dead = true;
                epoll_ctl(g_epfd, EPOLL_CTL_DEL, fd, NULL);
            }
            pthread_mutex_unlock(&g_mu);
            if (busy) continue;
            if (c->state == C_WRITING) {
                if (e & (EPOLLERR | EPOLLHUP)) conn_free(c);
                else if (e & EPOLLOUT) flush_write(c);
                continue;
            }
            if (e & EPOLLIN) on_readable(c);
            else if (e & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) conn_free(c);
        }
    }
    pthread_mutex_lock(&g_mu);
    g_stopping = true;
    pthread_cond_broadcast(&g_cv);
    pthread_cond_broadcast(&g_stop_cv);
    pthread_mutex_unlock(&g_mu);
    return NULL;
}

/* Binds "host:port" (port 0 picks a free one) and starts the I/O thread.
 * Returns the bound port, or -1 with a message on stderr. */
int64_t ib_http_listen(ib_slice addr) {
    char buf[512];
    if (addr.len <= 0 || addr.len >= (int64_t)sizeof buf) return -1;
    memcpy(buf, addr.data, (size_t)addr.len);
    buf[addr.len] = 0;
    char *colon = strrchr(buf, ':');
    if (!colon) { fprintf(stderr, "address must be host:port\n"); return -1; }
    *colon = 0;
    const char *host = buf, *port = colon + 1;
    if (host[0] == '[') { host++; char *rb = strchr(host, ']'); if (rb) *rb = 0; }
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE };
    struct addrinfo *res;
    int gai = getaddrinfo(*host ? host : NULL, port, &hints, &res);
    if (gai) { fprintf(stderr, "resolve %s: %s\n", host, gai_strerror(gai)); return -1; }
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 1024) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) { fprintf(stderr, "listen on %s:%s: %s\n", host, port, strerror(errno)); return -1; }
    struct sockaddr_storage ss; socklen_t sl = sizeof ss;
    getsockname(fd, (struct sockaddr *)&ss, &sl);
    int64_t bound = ss.ss_family == AF_INET6 ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port)
                                             : ntohs(((struct sockaddr_in *)&ss)->sin_port);

    g_listen = fd;
    g_epfd = epoll_create1(EPOLL_CLOEXEC);
    g_evfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    g_conns_cap = 1024;
    g_conns = calloc((size_t)g_conns_cap, sizeof *g_conns);
    struct epoll_event ev = { .events = EPOLLIN, .data.fd = g_listen };
    epoll_ctl(g_epfd, EPOLL_CTL_ADD, g_listen, &ev);
    ev.data.fd = g_evfd;
    epoll_ctl(g_epfd, EPOLL_CTL_ADD, g_evfd, &ev);

    struct sigaction sa = { .sa_handler = on_signal };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    pthread_create(&g_io, NULL, io_main, NULL);
    return bound;
}

/* Blocks for the next request. Appends method|target|headers|body to `out`
 * (lengths in `meta`) and returns true; false once the server is stopping. */
bool ib_http_next(int64_t slot, ib_req_meta *meta, gs_rref out) {
    pthread_mutex_lock(&g_mu);
    if (slot >= 0 && slot < MAX_SLOTS) g_inflight[slot] = 0;
    while (g_jobs_len == 0 && !g_stopping) pthread_cond_wait(&g_cv, &g_mu);
    if (g_jobs_len == 0) { pthread_mutex_unlock(&g_mu); return false; }
    job j = g_jobs[g_jobs_head];
    g_jobs_head = (g_jobs_head + 1) % g_jobs_cap;
    g_jobs_len--;
    if (slot >= 0 && slot < MAX_SLOTS) g_inflight[slot] = j.conn_id;
    pthread_mutex_unlock(&g_mu);
    *meta = j.meta;
    gs_bld_append(out, j.data, j.meta.method_len + j.meta.target_len + j.meta.headers_len + j.meta.body_len);
    free(j.data);
    return true;
}

static void respond_locked(int64_t id, int status, const uint8_t *h, int64_t hl, const uint8_t *b, int64_t bl) {
    int fd = (int)(uint32_t)id;
    uint32_t gen = (uint32_t)(id >> 32);
    conn *c = fd >= 0 && fd < g_conns_cap ? g_conns[fd] : NULL;
    if (!c || c->gen != gen || c->state != C_BUSY) return;
    set_response(c, status, h, hl, b, bl);
    c->state = C_WRITING;
    if (g_done_len == g_done_cap) {
        g_done_cap = g_done_cap ? g_done_cap * 2 : 64;
        g_done = realloc(g_done, g_done_cap * sizeof *g_done);
    }
    g_done[g_done_len++] = fd;
    uint64_t one = 1;
    ssize_t r = write(g_evfd, &one, sizeof one);
    (void)r;
}

/* `headers` is zero or more complete "name: value\r\n" lines. */
void ib_http_respond(int64_t slot, int64_t id, int64_t status, ib_slice headers, ib_slice body) {
    pthread_mutex_lock(&g_mu);
    if (slot >= 0 && slot < MAX_SLOTS && g_inflight[slot] == id) g_inflight[slot] = 0;
    respond_locked(id, (int)status, headers.data, headers.len, body.data, body.len);
    pthread_mutex_unlock(&g_mu);
}

/* A worker in `slot` died mid-request: answer its client so it doesn't hang. */
void ib_http_abandon(int64_t slot) {
    static const char ct[] = "content-type: text/plain; charset=utf-8\r\n";
    static const char msg[] = "Internal server error";
    pthread_mutex_lock(&g_mu);
    if (slot >= 0 && slot < MAX_SLOTS && g_inflight[slot]) {
        respond_locked(g_inflight[slot], 500, (const uint8_t *)ct, sizeof ct - 1,
                       (const uint8_t *)msg, sizeof msg - 1);
        g_inflight[slot] = 0;
    }
    pthread_mutex_unlock(&g_mu);
}

bool ib_http_running(void) { return !g_stop_signal; }

/* Waits up to `ms` for shutdown; true if the server is stopping. */
bool ib_http_wait_stop(int64_t ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (ms % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&g_mu);
    while (!g_stopping) {
        if (pthread_cond_timedwait(&g_stop_cv, &g_mu, &ts) == ETIMEDOUT) break;
    }
    bool s = g_stopping;
    pthread_mutex_unlock(&g_mu);
    return s;
}

void ib_http_join(void) { pthread_join(g_io, NULL); }
