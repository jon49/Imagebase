// ImageBase server: the CRDT sync API, shared spaces, published pages and the
// account endpoints, in one Goose program over a little C (native/).
//
//     imagebase [options] [serve]          run the HTTP server (the default)
//     imagebase [options] migrate          create or upgrade the database, then exit
//     imagebase [options] prune            run the nightly prune now
//     imagebase [options] user list
//     imagebase [options] user verify|delete|admin|unadmin <email>
//     imagebase [options] owner set <app> <email>
//     imagebase [options] owner list
//
// See `imagebase --help` for the options.
import std;
import os;
import json;
import exception;
import .util;
import .config;
import .db;
import .http;
import .auth;
import .sync;
import .spaces;
import .pages;
import .maintenance;

// --- routing -------------------------------------------------------------------

fn route(c: Ctx&) {
    let seg = segments(c.path);
    let n = seg.len;
    let m = c.method;
    guard n >= 2 && seg[0] == "api" || n >= 1 && seg[0] == "_" else { fail(404, "Not found"); }

    if seg[0] == "_" {
        // /_/auth/reset_password/update/{code}: the page the reset mail links to.
        if n == 5 && seg[1] == "auth" && seg[2] == "reset_password" && seg[3] == "update" {
            guard m == "GET" || m == "POST" else { fail(405, "Method not allowed"); }
            reset_form(c, seg[4]);
            return;
        }
        fail(404, "Not found");
    }

    if n >= 4 && seg[1] == "auth" && seg[2] == "v1" {
        let what = seg[3];
        if n == 4 {
            if what == "register" { want(c, "POST"); register(c); return; }
            if what == "login" { want(c, "POST"); login(c); return; }
            if what == "refresh" { want(c, "POST"); refresh(c); return; }
            if what == "logout" { guard m == "POST" || m == "GET" else { fail(405, "Method not allowed"); } logout(c); return; }
            if what == "status" { want(c, "GET"); status(c); return; }
            if what == "delete" { want(c, "DELETE"); delete_account(c); return; }
            if what == "change_password" { want(c, "POST"); change_password(c); return; }
        }
        if n == 5 && what == "reset_password" {
            if seg[4] == "request" { want(c, "POST"); reset_request(c); return; }
            if seg[4] == "update" { want(c, "POST"); reset_update(c); return; }
        }
        if n == 6 && what == "verify_email" && seg[4] == "confirm" { want(c, "GET"); verify_email(c, seg[5]); return; }
        fail(404, "Not found");
    }

    if seg[1] == "data" && n == 3 { want(c, "POST"); sync_data(c, app_id(seg[2])); return; }

    if seg[1] == "pages" && n == 4 { want(c, "GET"); serve_page(c, app_id(seg[2]), seg[3]); return; }

    if seg[1] == "records" && n >= 4 && seg[2] == "v1" && seg[3] == "pages" {
        if n == 4 { want(c, "POST"); create_page(c); return; }
        if n == 5 {
            if m == "PATCH" { update_page(c, seg[4]); return; }
            if m == "DELETE" { delete_page(c, seg[4]); return; }
            fail(405, "Method not allowed");
        }
    }

    if seg[1] == "spaces" && n >= 3 {
        let app = app_id(seg[2]);
        if n == 3 { want(c, "POST"); create_space(c, app); return; }
        if n == 5 && seg[4] == "members" { want(c, "GET"); list_members(c, app, seg[3]); return; }
        if n == 6 && seg[4] == "members" { want(c, "DELETE"); remove_member(c, app, seg[3], seg[5]); return; }
        if n == 5 && seg[4] == "invites" { want(c, "POST"); create_invite(c, app, seg[3]); return; }
    }

    if seg[1] == "invites" && n >= 4 {
        let app = app_id(seg[2]);
        if n == 4 { want(c, "GET"); get_invite(c, app, seg[3]); return; }
        if n == 5 && seg[4] == "accept" { want(c, "POST"); accept_invite(c, app, seg[3]); return; }
    }

    fail(404, "Not found");
}

// HEAD is answered as GET; the front end sends the headers only.
fn want(c: Ctx&, method: const u8[:]) {
    if c.method != method && !(method == "GET" && c.method == "HEAD") { fail(405, "Method not allowed"); }
}

// The {app} path segment namespaces every read and write.
fn app_id(s: const u8[:]) -> const u8[:] {
    if s.len == 0 { fail(400, "app id is required"); }
    return s;
}

// CORS: with --cors '*' (the default, matching TrailBase) any Origin is echoed back.
fn cors(c: Ctx&) {
    let origin = header(c, "origin");
    guard origin.len > 0 && CFG.cors_origin.len > 0 else { return; }
    guard CFG.cors_origin == "*" || CFG.cors_origin == origin else { return; }
    format(c.hdrs, "access-control-allow-origin: ", origin, "\r\naccess-control-allow-credentials: true\r\nvary: origin\r\n");
    if c.method == "OPTIONS" {
        c.hdrs.append("access-control-allow-methods: GET, POST, PATCH, DELETE, OPTIONS\r\n");
        let req = header(c, "access-control-request-headers");
        if req.len > 0 { format(c.hdrs, "access-control-allow-headers: ", req, "\r\n"); }
        c.hdrs.append("access-control-max-age: 86400\r\n");
    }
}

// Runs one request; returns the status. The body is left in `out`.
fn handle(meta: ReqMeta&, buf: const u8[:], out: u8[>..]&, hdrs: u8[>..]&) -> i64 {
    let m_end = meta.method_len;
    let t_end = m_end + meta.target_len;
    let h_end = t_end + meta.headers_len;
    let path, query, _q = split_once(buf[m_end..t_end], '?');
    var c = Ctx {
        method: buf[..m_end], path: path, query: query,
        headers: buf[t_end..h_end], body: buf[h_end..h_end + meta.body_len],
        out: out, hdrs: hdrs, ctype: TEXT,
    };
    var status: i64 = 200;
    if c.method == "OPTIONS" {
        cors(c);
        return 204;
    }
    var err: u8[>..] = [];
    fn run_route() { route(c); }
    exception::try<Fail>(run_route) { e =>
        rollback_if_open();
        err.append(e.msg);
        status = e.status;
    };
    cors(c);
    let ctype = if status >= 400 { TEXT } else { c.ctype };
    format(hdrs, "content-type: ", ctype, "\r\n");
    // `c` is done with: a failure's message replaces whatever was written.
    if status >= 400 {
        out.clear();
        out.append(err);
    }
    return status;
}

// --- workers -------------------------------------------------------------------

fn db_path() -> u8[>..] { str(CFG.data_dir, "/imagebase.db") }

thread_fn worker(slot: i64) {
    DB = ib_db_open(db_path(), slot);
    if DB == 0 { abort("cannot open the database"); }
    var meta = ReqMeta { 0, 0, 0, 0, 0 };
    loop {
        var big = false;
        {
            var buf: u8[>..] = [];
            guard ib_http_next(slot, meta, buf) else { break; }
            let t0 = clock_ns();
            var out: u8[>..] = [];
            var hdrs: u8[>..] = [];
            let status = handle(meta, buf, out, hdrs);
            ib_http_respond(slot, meta.conn, status, hdrs, out);
            if CFG.access_log || status >= 500 {
                let m_end = meta.method_len;
                log(str(buf[..m_end], " ", buf[m_end..m_end + meta.target_len], " ", status, " ",
                        (clock_ns() - t0) / 1000, "us"));
            }
            big = buf.len + out.len > 4 * 1024 * 1024;
        }
        // A large page upload or sync leaves its pages mapped above the stack
        // tops; hand them back so one big request doesn't pin the RSS.
        if big { trim_memory(); }
    }
    ib_db_close(DB);
}

// Restarts a worker that dies (a failed check or abort) after answering its
// in-flight request with a 500 and closing, so rolling back, its connection.
thread_fn supervise(slot: i64) {
    var why: u8[>..] = [];
    while !thread_wait(thread_spawn_contained(worker, slot), why) {
        log(str("worker ", slot, " died: ", why));
        ib_http_abandon(slot);
        ib_db_reclaim(slot);
        why.clear();
    }
}

// Nightly maintenance at 03:30 UTC.
thread_fn scheduler() {
    loop {
        if ib_http_wait_stop(until_prune(now()) * 1000) { break; }
        DB = ib_db_open(db_path(), -1);
        if DB == 0 { log("prune: cannot open the database"); continue; }
        fn job() { log(str("prune: deleted ", prune(), " overwritten row(s)")); }
        exception::try<Fail>(job) { e => rollback_if_open(); log(str("prune failed: ", e.msg)); };
        ib_db_close(DB);
    }
}

// --- startup -------------------------------------------------------------------

fn set<B>(dst: B&, v: const u8[:]) {
    if v.len > dst.cap { abort(str("value too long: ", v)); }
    dst.clear();
    dst.append(v);
}

fn usage() {
    write_stdout("""
        usage: imagebase [options] [serve | migrate | prune | user ... | owner ...]

          serve                      run the HTTP server (default)
          migrate                    create or upgrade the database and exit
          prune                      delete overwritten sync rows older than a month
          user list                  list accounts
          user verify <email>        mark an account's email as verified
          user delete <email>        delete an account (as the API's self-delete does)
          user admin|unadmin <email> set or clear the admin flag
          owner set <app> <email>    make <email> the page owner of <app>
          owner list                 list page owners

        options:
          --data DIR          data directory (default ./data): imagebase.db, secrets/
          --address H:P       listen address (default localhost:4000; port 0 picks one)
          --site-url URL      public base URL used in emailed links (default http://<address>)
          --workers N         request worker threads (default: hardware threads)
          --dev               log emails to stderr instead of sending them
          --sendmail CMD      sendmail-compatible command (default /usr/sbin/sendmail)
          --mail-from ADDR    From: address of outgoing mail
          --app-name NAME     product name used in emails (default ImageBase)
          --cors ORIGIN       allowed CORS origin, '*' for any (default), '' for none
          --auth-ttl SECS     auth token lifetime (default 3600)
          --refresh-ttl SECS  refresh token lifetime (default 2592000)
          --access-log        log every request to stderr
        """);
}

fn int_arg(v: const u8[:]) -> i64 {
    let n, ok = parse_int(v);
    if !ok || n < 0 { abort(str("not a number: ", v)); }
    return n;
}

fn load_key() {
    let dir = str(CFG.data_dir, "/secrets");
    make_dir(dir);
    let path = str(dir, "/jwt.key");
    var hex: u8[>..] = [];
    if !read_file(path, hex) {
        var raw: u8[32] = [0; 32];
        ib_random(raw);
        format_hex(hex, raw);
        if !write_file_atomic(path, hex) { abort(str("cannot write ", path)); }
        ib_chmod_private(path);
    }
    let t = trim(hex);
    if t.len != 64 { abort(str(path, " must hold 64 hex digits")); }
    for i in 32 {
        JWT_KEY[i] = (ascii::hex_value(t[2 * i]) * 16 + ascii::hex_value(t[2 * i + 1])) as! u8;
    }
}

extern fn ib_chmod_private(path: const u8[:]);

fn serve() {
    load_key();
    let port = ib_http_listen(CFG.address);
    if port < 0 { exit(1); }
    var n = CFG.workers;
    if n <= 0 { n = max(2, hardware_threads()); }
    if n > 256 { n = 256; }
    log(str("imagebase listening on ", CFG.address, " (port ", port, "), ", n, " workers, data in ", CFG.data_dir,
            if CFG.dev { ", dev mode" } else { "" }));
    var ids: i64[>..] = [];
    for slot in n { ids.push(thread_spawn(supervise, slot)); }
    let sched = thread_spawn(scheduler);
    for id in ids { thread_wait(id); }
    thread_wait(sched);
    ib_http_join();
    log("imagebase stopped");
}

fn find_user(email: const u8[:]) -> u8[16] {
    let st = query("SELECT id FROM _user WHERE email = ?1 OR unverified_email = ?1");
    defer finish(st);
    bind_text(st, 1, email);
    if !row(st) { fail(1, str("no such user: ", email)); }
    return col_id(st, 0);
}

fn user_cmd(cmd: const u8[:], email: const u8[:]) {
    let id = find_user(email);
    if cmd == "verify" {
        let st = query("""
            UPDATE _user SET email = coalesce(email, unverified_email), unverified_email = NULL,
              email_verification_code = NULL, updated = UNIXEPOCH() WHERE id = ?1
            """);
        defer finish(st);
        bind_blob(st, 1, id);
        run(st);
    } else if cmd == "delete" {
        let st = query("DELETE FROM _user WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        run(st);
    } else if cmd == "admin" || cmd == "unadmin" {
        let st = query("UPDATE _user SET admin = ?2, updated = UNIXEPOCH() WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        bind_int(st, 2, if cmd == "admin" { 1 } else { 0 });
        run(st);
    } else {
        usage();
        exit(2);
    }
    print(cmd, " ", email, ": ok");
}

fn list_users() {
    let st = query("SELECT id, coalesce(email, unverified_email), email IS NOT NULL, admin, created FROM _user ORDER BY created");
    defer finish(st);
    var line: u8[>..] = [];
    while row(st) {
        line.clear();
        format_uuid(line, col_id(st, 0));
        line.push(' ');
        col_append(st, 1, line);
        if col_int(st, 2) == 0 { line.append(" (unverified)"); }
        if col_int(st, 3) == 1 { line.append(" (admin)"); }
        print(line);
    }
}

fn owner_set(app: const u8[:], email: const u8[:]) {
    let id = find_user(email);
    let st = query("INSERT INTO app_owners (app, owner) VALUES (?1, ?2) ON CONFLICT (app) DO UPDATE SET owner = excluded.owner");
    defer finish(st);
    bind_text(st, 1, app);
    bind_blob(st, 2, id);
    run(st);
    print("owner of ", app, ": ", email);
}

fn list_owners() {
    let st = query("SELECT o.app, u.email FROM app_owners o JOIN _user u ON u.id = o.owner ORDER BY o.app");
    defer finish(st);
    var line: u8[>..] = [];
    while row(st) {
        line.clear();
        col_append(st, 0, line);
        line.append(": ");
        col_append(st, 1, line);
        print(line);
    }
}

fn main() {
    set(CFG.data_dir, "data");
    set(CFG.address, "localhost:4000");
    set(CFG.sendmail, "/usr/sbin/sendmail");
    set(CFG.app_name, "ImageBase");
    set(CFG.cors_origin, "*");
    CFG.auth_ttl = 3600;
    CFG.refresh_ttl = 30 * 86400;

    let argv = args();
    var rest: const u8[:][>..] = [];
    var i = 1;
    while i < argv.len {
        let a = argv[i];
        let has_next = i + 1 < argv.len;
        fn next() -> const u8[:] {
            if !has_next { abort(str(a, " needs a value")); }
            i++;
            return argv[i];
        }
        if a == "--help" || a == "-h" { usage(); return; }
        else if a == "--dev" { CFG.dev = true; }
        else if a == "--access-log" { CFG.access_log = true; }
        else if a == "--data" { set(CFG.data_dir, next()); }
        else if a == "--address" { set(CFG.address, next()); }
        else if a == "--site-url" { set(CFG.site_url, next()); }
        else if a == "--sendmail" { set(CFG.sendmail, next()); }
        else if a == "--mail-from" { set(CFG.mail_from, next()); }
        else if a == "--app-name" { set(CFG.app_name, next()); }
        else if a == "--cors" { set(CFG.cors_origin, next()); }
        else if a == "--workers" { CFG.workers = int_arg(next()); }
        else if a == "--auth-ttl" { CFG.auth_ttl = int_arg(next()); }
        else if a == "--refresh-ttl" { CFG.refresh_ttl = int_arg(next()); }
        else if a.len > 0 && a[0] == '-' { write_stderr(str("unknown option ", a, "\n")); usage(); exit(2); }
        else { rest.push(a); }
        i++;
    }
    if CFG.site_url.len == 0 { set(CFG.site_url, str("http://", CFG.address)); }
    while CFG.site_url.len > 0 && CFG.site_url[CFG.site_url.len - 1] == '/' { CFG.site_url.pop(); }
    if CFG.mail_from.len == 0 { set(CFG.mail_from, str(CFG.app_name, " <noreply@localhost>")); }

    if !make_dir(CFG.data_dir) { abort(str("cannot create ", CFG.data_dir)); }
    DB = ib_db_open(db_path(), -1);
    if DB == 0 { exit(1); }
    var code = 0;
    fn setup() { migrate(); }
    exception::try<Fail>(setup) { e => log(e.msg); code = 1; };
    if code != 0 { exit(code); }

    let cmd = if rest.len > 0 { rest[0] } else { "serve" };
    fn run_cmd() {
        if cmd == "serve" {
            ib_db_close(DB);
            DB = 0;
            serve();
        } else if cmd == "migrate" {
        } else if cmd == "prune" {
            print("deleted ", prune(), " overwritten row(s)");
        } else if cmd == "user" && rest.len == 2 && rest[1] == "list" {
            list_users();
        } else if cmd == "user" && rest.len == 3 {
            user_cmd(rest[1], rest[2]);
        } else if cmd == "owner" && rest.len == 4 && rest[1] == "set" {
            owner_set(rest[2], rest[3]);
        } else if cmd == "owner" && rest.len == 2 && rest[1] == "list" {
            list_owners();
        } else {
            usage();
            code = 2;
        }
    }
    exception::try<Fail>(run_cmd) { e => log(e.msg); code = 1; };
    if DB != 0 { ib_db_close(DB); }
    exit(code);
}
