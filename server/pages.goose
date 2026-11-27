// Published HTML pages.
//
// Writes keep the TrailBase Record API's shape so clients don't change:
//   POST   /api/records/v1/pages        create or overwrite (JSON or multipart)
//   PATCH  /api/records/v1/pages/{id}   replace the file and/or move it to a space
//   DELETE /api/records/v1/pages/{id}
// Writers are the user registered in `app_owners` for the page's app, or a
// member of the page's space (which must belong to the same app). Anyone else,
// including an anonymous caller, gets 403.
//
// Reads are public: GET /api/pages/{app}/{id} returns the bytes inline as
// text/html. The file is stored in the row itself; there is no object store.
import std;
import json;
import exception;
import .util;
import .db;
import .http;
import .auth;

let MAX_PAGE = 16 * 1024 * 1024;

fn writer(c: Ctx&) -> u8[16] {
    let id, ok = caller_or_none(c);
    if !ok { fail(403, "Forbidden"); }
    return id;
}

fn is_owner(app: const u8[:], user: const u8[:]) -> bool {
    var yes = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("SELECT 1 FROM app_owners WHERE app = ?1 AND owner = ?2");
        defer finish(st);
        bind_text(st, 1, app);
        bind_blob(st, 2, user);
        yes = row(st);
    }
    return yes;
}

fn is_space_member(space: const u8[:], app: const u8[:], user: const u8[:]) -> bool {
    var yes = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("""
            SELECT 1 FROM space_members m JOIN spaces s ON s.id = m.space
              WHERE m.space = ?1 AND m.user = ?2 AND s.app = ?3
            """);
        defer finish(st);
        bind_blob(st, 1, space);
        bind_blob(st, 2, user);
        bind_text(st, 3, app);
        yes = row(st);
    }
    return yes;
}

// What a create or update carries. `html` holds the decoded file bytes.
struct Upload {
    id: u8[16], has_id: bool,
    app: u8[..256],
    space: u8[16], has_space: bool,
    filename: u8[..256],
    content_type: u8[..128],
    has_html: bool,
}

fn set_space(u: Upload&, s: const u8[:]) {
    let id, ok = parse_uuid(s);
    if !ok { fail(400, "space must be a UUID"); }
    u.space = id;
    u.has_space = true;
}

fn limited<B>(dst: B&, v: const u8[:], what: const u8[:]) {
    dst.clear();
    if v.len > dst.cap { exception::throw(Fail { status: 400, msg: str(what, " is too long") }); }
    dst.append(v);
}

// Reads a JSON or multipart body. The file's bytes are appended to `html`.
fn read_upload(c: Ctx&, html: u8[>..]&) -> Upload {
    var u = Upload { .. };
    if is_multipart(c) { read_multipart(c, u, html); return u; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root = parse_json_body(c, doc, decoded);
    guard root else { fail(400, "Missing body"); }
    let id_s, has_id = json::as_string(json::member(root, "id"));
    if has_id {
        let id, ok = parse_uuid(id_s);
        if !ok { fail(400, "id must be a UUID"); }
        u.id = id;
        u.has_id = true;
    }
    limited(u.app, json_str(root, "app"), "app");
    let sp = json::member(root, "space");
    if sp {
        let s, is_str = json::as_string(sp);
        if is_str { set_space(u, s); }
    }
    let file = json::member(root, "html");
    if file {
        limited(u.filename, json_str(file, "filename"), "filename");
        limited(u.content_type, json_str(file, "content_type"), "content_type");
        if !b64_decode_any(html, json_str(file, "data")) { fail(400, "html.data must be base64"); }
        u.has_html = true;
    }
    return u;
}

fn read_multipart(c: Ctx&, u: Upload&, html: u8[>..]&) {
    let ct = header(c, "content-type");
    let b = find(ct, "boundary=");
    if b < 0 { fail(400, "multipart body without a boundary"); }
    var boundary: u8[>..] = [];
    boundary.append("--");
    var bv = ct[b + 9..];
    let semi = find(bv, ";");
    if semi >= 0 { bv = bv[..semi]; }
    bv = trim(bv);
    if bv.len >= 2 && bv[0] == '"' && bv[bv.len - 1] == '"' { bv = bv[1..bv.len - 1]; }
    boundary.append(bv);

    var rest = c.body;
    let first = find(rest, boundary);
    if first < 0 { fail(400, "malformed multipart body"); }
    rest = rest[first + boundary.len..];
    loop {
        if rest.len >= 2 && rest[0] == '-' && rest[1] == '-' { break; }   // closing delimiter
        if rest.len < 2 || rest[0] != '\r' || rest[1] != '\n' { fail(400, "malformed multipart body"); }
        rest = rest[2..];
        let head_end = find(rest, "\r\n\r\n");
        if head_end < 0 { fail(400, "malformed multipart body"); }
        let head = rest[..head_end];
        rest = rest[head_end + 4..];
        var delim: u8[>..] = [];
        delim.append("\r\n");
        delim.append(boundary);
        let end = find(rest, delim);
        if end < 0 { fail(400, "malformed multipart body"); }
        let value = rest[..end];
        rest = rest[end + delim.len..];

        let name = part_param(head, "name=\"");
        if name == "id" {
            let id, ok = parse_uuid(trim(value));
            if !ok { fail(400, "id must be a UUID"); }
            u.id = id;
            u.has_id = true;
        } else if name == "app" {
            limited(u.app, trim(value), "app");
        } else if name == "space" {
            if trim(value).len > 0 { set_space(u, trim(value)); }
        } else if name == "html" {
            limited(u.filename, part_param(head, "filename=\""), "filename");
            let ctype = part_header(head, "content-type");
            limited(u.content_type, if ctype.len > 0 { ctype } else { "text/html" }, "content_type");
            html.append(value);
            u.has_html = true;
        }
    }
}

// A header's value in a part's header block, or "".
fn part_header(head: const u8[:], name: const u8[:]) -> const u8[:] {
    var rest = head;
    while rest.len > 0 {
        let line, after, _found = split_once(rest, "\r\n");
        rest = after;
        let k, v, ok = split_once(line, ':');
        if ok && ascii_eq_nocase(trim(k), name) { return trim(v); }
    }
    return "";
}

// The quoted value after `key` (which includes the opening quote) in a part's headers.
fn part_param(head: const u8[:], key: const u8[:]) -> const u8[:] {
    var at = 0;
    loop {
        let i = find(head[at..], key);
        if i < 0 { return ""; }
        let p = at + i;
        // `name="` must not match the tail of `filename="`.
        if p == 0 || head[p - 1] == ' ' || head[p - 1] == ';' {
            let v = head[p + key.len..];
            let q = find(v, "\"");
            return if q < 0 { v } else { v[..q] };
        }
        at = p + key.len;
    }
}

fn write_ids(c: Ctx&, id: const u8[:]) {
    c.out.append("{\"ids\":[\"");
    b64url(c.out, id, true);
    c.out.append("\"]}");
    c.ctype = JSON;
}

// POST /api/records/v1/pages. Re-posting an existing id overwrites it.
fn create_page(c: Ctx&) {
    let user = writer(c);
    var html: u8[>..] = [];
    let u = read_upload(c, html);
    if !u.has_id { fail(400, "id is required"); }
    if u.app.len == 0 { fail(400, "app is required"); }
    if !u.has_html { fail(400, "html is required"); }
    if html.len > MAX_PAGE { fail(413, "page too large"); }
    let space: const u8[:] = if u.has_space { u.space[..] } else { "" };

    begin_write();
    // An existing row with this id: who may overwrite it.
    var exists = false;
    var row_app: u8[>..] = [];
    var row_space: u8[16] = [0; 16];
    var row_has_space = false;
    {
        let st = query("SELECT app, space FROM pages WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, u.id);
        if row(st) {
            exists = true;
            col_append(st, 0, row_app);
            row_has_space = !col_is_null(st, 1);
            row_space = col_id(st, 1);
        }
    }
    let as_owner = is_owner(u.app, user) && (!exists || row_app == u.app);
    let as_member = u.has_space && is_space_member(space, u.app, user)
                    && (!exists || (row_has_space && row_space == u.space));
    if !as_owner && !as_member { fail(403, "Forbidden"); }

    let st = query("""
        INSERT INTO pages (id, app, space, filename, content_type, html) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          ON CONFLICT (id) DO UPDATE SET app = excluded.app, space = excluded.space,
          filename = excluded.filename, content_type = excluded.content_type,
          html = excluded.html, updated = UNIXEPOCH()
        """);
    defer finish(st);
    bind_blob(st, 1, u.id);
    bind_text(st, 2, u.app);
    if u.has_space { bind_blob(st, 3, u.space); } else { bind_null(st, 3); }
    bind_text(st, 4, u.filename);
    bind_text(st, 5, if u.content_type.len > 0 { u.content_type[..] } else { "text/html" });
    bind_blob(st, 6, html);
    run(st);
    commit();
    write_ids(c, u.id);
}

// The page row's app and space, for the update/delete rules; 404 if absent.
struct PageRow { app: u8[..256], space: u8[16], has_space: bool }

fn load_row(id: const u8[:]) -> PageRow {
    var r = PageRow { .. };
    let st = query("SELECT app, space FROM pages WHERE id = ?1");
    defer finish(st);
    bind_blob(st, 1, id);
    if !row(st) { fail(404, "no such page"); }
    var app: u8[>..] = [];
    col_append(st, 0, app);
    limited(r.app, app, "app");
    r.has_space = !col_is_null(st, 1);
    r.space = col_id(st, 1);
    return r;
}

fn may_modify(r: PageRow&, user: const u8[:]) -> bool {
    is_owner(r.app, user) || (r.has_space && is_space_member(r.space, r.app, user))
}

// PATCH /api/records/v1/pages/{id}
fn update_page(c: Ctx&, id_s: const u8[:]) {
    let user = writer(c);
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "id must be a UUID"); }
    var html: u8[>..] = [];
    let u = read_upload(c, html);
    if u.has_id && u.id != id { fail(400, "id can't be changed"); }
    begin_write();
    let r = load_row(id);
    if u.app.len > 0 && u.app != r.app { fail(400, "app can't be changed"); }
    // A member may update a page in their space but not move it to another one.
    let owner = is_owner(r.app, user);
    let member = r.has_space && is_space_member(r.space, r.app, user) && (!u.has_space || u.space == r.space);
    if !owner && !member { fail(403, "Forbidden"); }
    if u.has_space && !owner && !is_space_member(u.space, r.app, user) { fail(403, "Forbidden"); }
    if u.has_html {
        if html.len > MAX_PAGE { fail(413, "page too large"); }
        let st = query("UPDATE pages SET html = ?2, filename = ?3, content_type = ?4, updated = UNIXEPOCH() WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        bind_blob(st, 2, html);
        bind_text(st, 3, u.filename);
        bind_text(st, 4, if u.content_type.len > 0 { u.content_type[..] } else { "text/html" });
        run(st);
    }
    if u.has_space {
        let st = query("UPDATE pages SET space = ?2, updated = UNIXEPOCH() WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        bind_blob(st, 2, u.space);
        run(st);
    }
    commit();
}

// DELETE /api/records/v1/pages/{id}
fn delete_page(c: Ctx&, id_s: const u8[:]) {
    let user = writer(c);
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "id must be a UUID"); }
    begin_write();
    let r = load_row(id);
    if !may_modify(r, user) { fail(403, "Forbidden"); }
    let st = query("DELETE FROM pages WHERE id = ?1");
    defer finish(st);
    bind_blob(st, 1, id);
    run(st);
    commit();
    text(c, "deleted");
}

// GET /api/pages/{app}/{id}: public, inline HTML.
fn serve_page(c: Ctx&, app: const u8[:], id_s: const u8[:]) {
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "page id must be a UUID"); }
    let st = query("SELECT html FROM pages WHERE app = ?1 AND id = ?2");
    defer finish(st);
    bind_text(st, 1, app);
    bind_blob(st, 2, id);
    if !row(st) { fail(404, "no such page"); }
    col_append(st, 0, c.out);
    c.ctype = HTML;
}
