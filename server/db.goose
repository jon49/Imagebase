// SQLite access over native/db.c. Each thread opens its own connection into
// its own copy of the global `DB`; statements are cached in C by SQL text.
//
//     let st = query("SELECT ... WHERE id = ?1");
//     defer finish(st);
//     bind_blob(st, 1, id);
//     while row(st) { let n = col_int(st, 0); }
//
// Any SQLite error throws a 500 Fail (see util.goose).
//
// Goose v2026.4 bug: when a function whose `defer` is in its outermost block
// returns a bool and is inlined into an `if`/`while` condition, the false path
// skips the defer. A skipped `finish` leaves the statement holding a read
// snapshot, and the connection's next write fails with SQLITE_BUSY_SNAPSHOT.
// So a bool-returning helper puts its query and defer in an inner block and
// returns a local after it (repro: docs/goose-defer-bug.goose; upstream
// https://github.com/aardappel/goose/issues/431).
import std;
import exception;
import .util;

extern fn ib_db_open(path: const u8[:], slot: i64) -> i64;
extern fn ib_db_close(db: i64);
extern fn ib_db_reclaim(slot: i64);
extern fn ib_db_exec(db: i64, sql: const u8[:]) -> i64;
extern fn ib_db_prepare(db: i64, sql: const u8[:]) -> i64;
extern fn ib_db_finish(st: i64);
extern fn ib_db_bind_int(st: i64, i: i64, v: i64) -> i64;
extern fn ib_db_bind_null(st: i64, i: i64) -> i64;
extern fn ib_db_bind_text(st: i64, i: i64, v: const u8[:]) -> i64;
extern fn ib_db_bind_blob(st: i64, i: i64, v: const u8[:]) -> i64;
extern fn ib_db_step(st: i64) -> i64;
extern fn ib_db_col_type(st: i64, i: i64) -> i64;
extern fn ib_db_col_int(st: i64, i: i64) -> i64;
extern fn ib_db_col_append(st: i64, i: i64, out: u8[>..]&);
extern fn ib_db_col_copy(st: i64, i: i64, dst: u8[16]&, cap: i64) -> i64;
extern fn ib_db_changes(db: i64) -> i64;
extern fn ib_db_in_tx(db: i64) -> bool;
extern fn ib_db_errmsg(db: i64, out: u8[>..]&);
extern fn ib_db_write_lock(db: i64);
extern fn ib_db_write_unlock(db: i64);
extern fn ib_db_busy_stmts(db: i64, out: u8[>..]&) -> i64;

let SQLITE_ROW = 100;
let SQLITE_DONE = 101;
let SQLITE_NULL = 5;

var DB: i64 = 0;

fn db_error(what: const u8[:]) {
    var m: u8[>..] = [];
    format(m, "database error (", what, "): ");
    ib_db_errmsg(DB, m);
    m.append("; mid-step statements: ");
    ib_db_busy_stmts(DB, m);
    log(m);
    exception::throw(Fail { status: 500, msg: "Internal server error" });
}

fn exec(sql: const u8[:]) {
    if ib_db_exec(DB, sql) != 0 { db_error(sql); }
}

fn query(sql: const u8[:]) -> i64 {
    let st = ib_db_prepare(DB, sql);
    if st == 0 { db_error(sql); }
    return st;
}

fn finish(st: i64) { ib_db_finish(st); }

fn bind_int(st: i64, i: i64, v: i64) { ib_db_bind_int(st, i, v); }
fn bind_null(st: i64, i: i64) { ib_db_bind_null(st, i); }
fn bind_text(st: i64, i: i64, v: const u8[:]) { ib_db_bind_text(st, i, v); }
fn bind_blob(st: i64, i: i64, v: const u8[:]) { ib_db_bind_blob(st, i, v); }

// Steps once: true for a row, false when done; throws on an error.
fn row(st: i64) -> bool {
    let rc = ib_db_step(st);
    if rc == SQLITE_ROW { return true; }
    if rc != SQLITE_DONE { db_error("step"); }
    return false;
}

// Runs a statement that returns no rows to completion.
fn run(st: i64) { while row(st) { } }

fn col_int(st: i64, i: i64) -> i64 { ib_db_col_int(st, i) }
fn col_is_null(st: i64, i: i64) -> bool { ib_db_col_type(st, i) == SQLITE_NULL }
fn col_append(st: i64, i: i64, out: u8[>..]&) { ib_db_col_append(st, i, out); }

// A 16-byte BLOB column (an id).
fn col_id(st: i64, i: i64) -> u8[16] {
    var id: u8[16] = [0; 16];
    ib_db_col_copy(st, i, id, 16);
    return id;
}

fn changes() -> i64 { ib_db_changes(DB) }

// Read transactions see one snapshot; write transactions also take the
// process-wide write gate (native/db.c) so writers queue instead of retrying.
fn begin() { exec("BEGIN"); }
fn begin_write() {
    ib_db_write_lock(DB);
    exec("BEGIN IMMEDIATE");
}
fn commit() {
    exec("COMMIT");
    ib_db_write_unlock(DB);
}

// Called after a Fail unwinds a handler, so a half-done transaction (or a
// held write gate) never leaks into the next request on this connection.
fn rollback_if_open() {
    if ib_db_in_tx(DB) { ib_db_exec(DB, "ROLLBACK"); }
    ib_db_write_unlock(DB);
}
