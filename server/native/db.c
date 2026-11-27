/* Thin SQLite binding for Goose. Handles are opaque i64s. Each worker thread
 * opens its own connection, so nothing here is shared across threads.
 *
 * Prepared statements are cached per connection by SQL text: ib_db_prepare
 * hands out the cached statement unless it is already in use (a nested query
 * with the same SQL), in which case a one-off statement is prepared and
 * finalized again by ib_db_finish. */
#include "goose.h"

#include <pthread.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } ib_slice;

#define CACHE_SLOTS 256

typedef struct stmt {
    sqlite3_stmt *st;
    struct db *owner;
    char *sql; int64_t sql_len; uint64_t hash;
    bool busy, ephemeral;
} stmt;

typedef struct db {
    sqlite3 *h;
    stmt *cache[CACHE_SLOTS];
    int64_t slot;
    bool holds_write;
} db;

/* One writer at a time, process-wide. SQLite allows a single write
 * transaction anyway; queueing here (FIFO-ish on a condvar) instead of in
 * SQLite's busy handler, which sleeps and retries, keeps write latency flat
 * under contention. Released from any thread, so a supervisor can free it
 * for a worker that died holding it. busy_timeout still covers writers in
 * other processes (the CLI, sqlite3). */
static pthread_mutex_t g_wmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wcv = PTHREAD_COND_INITIALIZER;
static bool g_wbusy;

void ib_db_write_lock(int64_t handle) {
    db *d = (db *)(intptr_t)handle;
    if (d->holds_write) return;
    pthread_mutex_lock(&g_wmu);
    while (g_wbusy) pthread_cond_wait(&g_wcv, &g_wmu);
    g_wbusy = true;
    d->holds_write = true;
    pthread_mutex_unlock(&g_wmu);
}

void ib_db_write_unlock(int64_t handle) {
    db *d = (db *)(intptr_t)handle;
    if (!d->holds_write) return;
    pthread_mutex_lock(&g_wmu);
    g_wbusy = false;
    d->holds_write = false;
    pthread_cond_signal(&g_wcv);
    pthread_mutex_unlock(&g_wmu);
}

/* Connections by worker slot, so a supervisor can close (and so roll back) the
 * connection of a worker that died mid-transaction. */
#define MAX_SLOTS 256
static db *g_slot_db[MAX_SLOTS];

static uint64_t fnv(const uint8_t *p, int64_t n) {
    uint64_t h = 1469598103934665603ull;
    for (int64_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

/* Process-wide SQLite settings, before the library initializes. Memory
 * statistics take a global mutex on every allocation; with a connection per
 * worker that is the main point of contention, and nothing here reads them. */
static pthread_once_t g_sqlite_once = PTHREAD_ONCE_INIT;
static void sqlite_setup(void) {
    sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0);
    sqlite3_initialize();
}

int64_t ib_db_open(ib_slice path, int64_t slot) {
    pthread_once(&g_sqlite_once, sqlite_setup);
    char *p = malloc((size_t)path.len + 1);
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    sqlite3 *h = NULL;
    int rc = sqlite3_open_v2(p, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL);
    free(p);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "sqlite open: %s\n", h ? sqlite3_errmsg(h) : sqlite3_errstr(rc));
        sqlite3_close(h);
        return 0;
    }
    sqlite3_busy_timeout(h, 10000);
    sqlite3_exec(h, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;"
                    "PRAGMA temp_store = MEMORY;", NULL, NULL, NULL);
    db *d = calloc(1, sizeof *d);
    d->h = h;
    d->slot = slot;
    if (slot >= 0 && slot < MAX_SLOTS) __atomic_store_n(&g_slot_db[slot], d, __ATOMIC_RELEASE);
    return (int64_t)(intptr_t)d;
}

void ib_db_close(int64_t handle) {
    db *d = (db *)(intptr_t)handle;
    if (!d) return;
    if (d->slot >= 0 && d->slot < MAX_SLOTS) __atomic_store_n(&g_slot_db[d->slot], NULL, __ATOMIC_RELEASE);
    ib_db_write_unlock(handle);
    for (int i = 0; i < CACHE_SLOTS; i++) {
        stmt *s = d->cache[i];
        if (!s) continue;
        free(s->sql);
        free(s);
    }
    /* Finalize everything, one-off statements a dead worker left behind included. */
    sqlite3_stmt *st;
    while ((st = sqlite3_next_stmt(d->h, NULL)) != NULL) sqlite3_finalize(st);
    sqlite3_close(d->h);
    free(d);
}

/* The worker in `slot` is gone: close its connection, rolling back anything open. */
void ib_db_reclaim(int64_t slot) {
    if (slot < 0 || slot >= MAX_SLOTS) return;
    db *d = __atomic_exchange_n(&g_slot_db[slot], NULL, __ATOMIC_ACQ_REL);
    if (d) { d->slot = -1; ib_db_close((int64_t)(intptr_t)d); }
}

bool ib_db_in_tx(int64_t handle) { return !sqlite3_get_autocommit(((db *)(intptr_t)handle)->h); }

/* Runs one or more statements with no results (migrations, BEGIN/COMMIT).
 * Returns the SQLite result code; 0 is success. */
int64_t ib_db_exec(int64_t handle, ib_slice sql) {
    db *d = (db *)(intptr_t)handle;
    char *s = malloc((size_t)sql.len + 1);
    memcpy(s, sql.data, (size_t)sql.len);
    s[sql.len] = 0;
    int rc = sqlite3_exec(d->h, s, NULL, NULL, NULL);
    free(s);
    return rc;
}

/* A ready-to-bind statement, or 0 on a prepare error (see ib_db_errmsg). */
int64_t ib_db_prepare(int64_t handle, ib_slice sql) {
    db *d = (db *)(intptr_t)handle;
    uint64_t h = fnv(sql.data, sql.len);
    stmt **slot = &d->cache[h % CACHE_SLOTS];
    stmt *s = *slot;
    if (s && s->hash == h && s->sql_len == sql.len && memcmp(s->sql, sql.data, (size_t)sql.len) == 0 && !s->busy) {
        s->busy = true;
        return (int64_t)(intptr_t)s;
    }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v3(d->h, (const char *)sql.data, (int)sql.len, SQLITE_PREPARE_PERSISTENT, &st, NULL) != SQLITE_OK)
        return 0;
    stmt *n = calloc(1, sizeof *n);
    n->st = st; n->owner = d; n->busy = true;
    n->hash = h; n->sql_len = sql.len;
    n->sql = malloc((size_t)sql.len ? (size_t)sql.len : 1);
    memcpy(n->sql, sql.data, (size_t)sql.len);
    if (s == NULL) *slot = n;              /* empty slot: cache it */
    else if (!s->busy) {                   /* collision: replace the idle entry */
        sqlite3_finalize(s->st); free(s->sql); free(s);
        *slot = n;
    } else n->ephemeral = true;            /* in use: one-off */
    return (int64_t)(intptr_t)n;
}

/* Resets the statement and returns it to the cache (or frees a one-off). */
void ib_db_finish(int64_t h) {
    stmt *s = (stmt *)(intptr_t)h;
    if (!s) return;
    sqlite3_reset(s->st);
    sqlite3_clear_bindings(s->st);
    s->busy = false;
    if (s->ephemeral) { sqlite3_finalize(s->st); free(s->sql); free(s); }
}

static sqlite3_stmt *S(int64_t h) { return ((stmt *)(intptr_t)h)->st; }

int64_t ib_db_bind_int(int64_t h, int64_t i, int64_t v) { return sqlite3_bind_int64(S(h), (int)i, v); }
int64_t ib_db_bind_null(int64_t h, int64_t i) { return sqlite3_bind_null(S(h), (int)i); }
int64_t ib_db_bind_text(int64_t h, int64_t i, ib_slice v) {
    return sqlite3_bind_text64(S(h), (int)i, (const char *)(v.len ? v.data : (const uint8_t *)""), (sqlite3_uint64)v.len,
                               SQLITE_TRANSIENT, SQLITE_UTF8);
}
int64_t ib_db_bind_blob(int64_t h, int64_t i, ib_slice v) {
    return sqlite3_bind_blob64(S(h), (int)i, v.len ? v.data : (const uint8_t *)"", (sqlite3_uint64)v.len, SQLITE_TRANSIENT);
}

/* 100 = a row, 101 = done, anything else an error. */
int64_t ib_db_step(int64_t h) { return sqlite3_step(S(h)); }

int64_t ib_db_col_type(int64_t h, int64_t i) { return sqlite3_column_type(S(h), (int)i); }
int64_t ib_db_col_int(int64_t h, int64_t i) { return sqlite3_column_int64(S(h), (int)i); }

/* Appends a TEXT or BLOB column's bytes (nothing for NULL). */
void ib_db_col_append(int64_t h, int64_t i, gs_rref out) {
    sqlite3_stmt *st = S(h);
    int t = sqlite3_column_type(st, (int)i);
    if (t == SQLITE_NULL) return;
    const void *p = t == SQLITE_BLOB ? sqlite3_column_blob(st, (int)i) : (const void *)sqlite3_column_text(st, (int)i);
    gs_bld_append(out, p, sqlite3_column_bytes(st, (int)i));
}

/* Copies up to `cap` bytes of a column into a fixed buffer; returns the column's length. */
int64_t ib_db_col_copy(int64_t h, int64_t i, uint8_t *dst, int64_t cap) {
    sqlite3_stmt *st = S(h);
    int t = sqlite3_column_type(st, (int)i);
    if (t == SQLITE_NULL) return 0;
    const void *p = t == SQLITE_BLOB ? sqlite3_column_blob(st, (int)i) : (const void *)sqlite3_column_text(st, (int)i);
    int64_t n = sqlite3_column_bytes(st, (int)i);
    memcpy(dst, p, (size_t)(n < cap ? n : cap));
    return n;
}

int64_t ib_db_changes(int64_t handle) { return sqlite3_changes64(((db *)(intptr_t)handle)->h); }

void ib_db_errmsg(int64_t handle, gs_rref out) {
    sqlite3 *h = ((db *)(intptr_t)handle)->h;
    char m[600];
    int n = snprintf(m, sizeof m, "%s (code %d)", sqlite3_errmsg(h), sqlite3_extended_errcode(h));
    gs_bld_append(out, m, n < (int)sizeof m ? n : (int)sizeof m - 1);
}

/* Debug aid: statements on this connection that are mid-step (hold a read). */
int64_t ib_db_busy_stmts(int64_t handle, gs_rref out) {
    sqlite3 *h = ((db *)(intptr_t)handle)->h;
    int64_t n = 0;
    for (sqlite3_stmt *st = sqlite3_next_stmt(h, NULL); st; st = sqlite3_next_stmt(h, st)) {
        if (sqlite3_stmt_busy(st)) {
            n++;
            const char *q = sqlite3_sql(st);
            gs_bld_append(out, q, (int64_t)strlen(q));
            gs_bld_append(out, "\n", 1);
        }
    }
    return n;
}
