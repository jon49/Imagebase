// Schema migrations and the nightly prune.
import std;
import .util;
import .db;

struct Migration { name: const u8[:], sql: const u8[:] }

// Applied in order, each once. Append new files; never edit a shipped one.
let MIGRATIONS = [
    Migration { name: "0001_schema", sql: embed_file("migrations/0001_schema.sql") },
];

fn migrate() {
    exec("CREATE TABLE IF NOT EXISTS _migrations (name TEXT PRIMARY KEY NOT NULL, applied INTEGER NOT NULL DEFAULT (UNIXEPOCH())) STRICT");
    for m in MIGRATIONS {
        var done = false;
        {
            let st = query("SELECT 1 FROM _migrations WHERE name = ?1");
            defer finish(st);
            bind_text(st, 1, m.name);
            done = row(st);
        }
        if done { continue; }
        begin_write();
        exec(m.sql);
        let st = query("INSERT INTO _migrations (name) VALUES (?1)");
        defer finish(st);
        bind_text(st, 1, m.name);
        run(st);
        commit();
        log(str("applied migration ", m.name));
    }
}

// Deletes rows superseded by a newer write for the same key in the same scope
// AND older than a month. The latest value per key is never deleted, and
// recent overwrites stay reconcilable. user_data is append-only, so without
// this it grows without bound. Returns the number of rows deleted.
fn prune() -> i64 {
    begin_write();
    exec("""
        DELETE FROM user_data
          WHERE id IN (
          SELECT id FROM (
          SELECT id, timestamp,
          ROW_NUMBER() OVER (
          PARTITION BY space, iif(space IS NULL, user, NULL), app, key
          ORDER BY id DESC) AS dup
          FROM user_data)
          WHERE dup > 1 AND timestamp < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 month'))
        """);
    let n = changes();
    exec("DELETE FROM _session WHERE expires < UNIXEPOCH()");
    exec("DELETE FROM _auth_throttle WHERE window_start < UNIXEPOCH() - 86400");
    commit();
    return n;
}

// Seconds from `t` (unix time) until the next 03:30 UTC.
fn until_prune(t: i64) -> i64 {
    let day = 86400;
    let at = 3 * 3600 + 30 * 60;
    let into = t % day;
    if into < at { at - into } else { day - into + at }
}
