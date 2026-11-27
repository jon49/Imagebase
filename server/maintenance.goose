// Schema migrations and the nightly prune.
import std;
import exception;
import .util;
import .db;
import .config;
import .pages;

struct Migration { name: const u8[:], sql: const u8[:] }

// Applied in order, each once. Append new files; never edit a shipped one.
let MIGRATIONS = [
    Migration { name: "0001_schema", sql: embed_file("migrations/0001_schema.sql") },
    Migration { name: "0002_single_app", sql: embed_file("migrations/0002_single_app.sql") },
    Migration { name: "0003_pages_to_files", sql: embed_file("migrations/0003_pages_to_files.sql") },
];

// Moves published pages out of the database before 0003 drops their table.
fn export_pages() {
    var n = 0;
    {
        let st = query("SELECT count(*) FROM pages");
        defer finish(st);
        if row(st) { n = col_int(st, 0); }
    }
    if n == 0 { return; }
    if CFG.pages_dir.len == 0 {
        exception::throw(Fail { status: 1, msg: str(
            "the database holds ", n, " published page(s), which now live as files: ",
            "run with --pages-dir DIR once so the migration can write them there") });
    }
    let st = query("SELECT id, space, html FROM pages");
    defer finish(st);
    var html: u8[>..] = [];
    while row(st) {
        html.clear();
        col_append(st, 2, html);
        store_page(col_id(st, 0), html, !col_is_null(st, 1), col_id(st, 1));
    }
    log(str("wrote ", n, " page(s) to ", CFG.pages_dir));
}

// Checks a database can take a migration; throws a Fail explaining why not.
fn precheck(name: const u8[:]) {
    if name == "0003_pages_to_files" { export_pages(); return; }
    if name != "0002_single_app" { return; }
    var apps: u8[>..] = [];
    var n = 0;
    {
        let st = query("""
            SELECT app FROM user_data UNION SELECT app FROM spaces
              UNION SELECT app FROM pages UNION SELECT app FROM app_owners ORDER BY 1
            """);
        defer finish(st);
        while row(st) {
            if n > 0 { apps.append(", "); }
            col_append(st, 0, apps);
            n++;
        }
    }
    if n > 1 {
        exception::throw(Fail { status: 1, msg: str(
            "this database holds data for several apps (", apps, "); a server now serves one. ",
            "Import each into its own data dir: tools/import-from-trailbase.py --app NAME") });
    }
}

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
        precheck(m.name);
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
          PARTITION BY space, iif(space IS NULL, user, NULL), key
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
