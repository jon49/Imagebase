// Published HTML pages.
//
// Writes keep the TrailBase Record API's shape so clients don't change:
//   POST   /api/records/v1/pages        create or overwrite (JSON or multipart)
//   PATCH  /api/records/v1/pages/{id}   replace the file and/or move it to a space
//   DELETE /api/records/v1/pages/{id}
// Writers are the page owner (`page_owner`, set with `imagebase owner set`) or
// a member of the page's space. Anyone else, including an anonymous caller,
// gets 403.
//
// Pages are files in the directory --pages-dir names (see "storage" below),
// so nginx can serve them directly; without --pages-dir publishing is off.
// The server's own GET /api/pages/{id} serves them too, inline as text/html.
import std;
import os;
import json;
import exception;
import .util;
import .db;
import .http;
import .auth;
import .config;

let MAX_PAGE = 16 * 1024 * 1024;

fn writer(c: Ctx&) -> u8[16] {
    let id, ok = caller_or_none(c);
    if !ok { fail(403, "Forbidden"); }
    return id;
}

fn is_owner(user: const u8[:]) -> bool {
    var yes = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("SELECT 1 FROM page_owner WHERE owner = ?1");
        defer finish(st);
        bind_blob(st, 1, user);
        yes = row(st);
    }
    return yes;
}

fn is_space_member(space: const u8[:], user: const u8[:]) -> bool {
    var yes = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("SELECT 1 FROM space_members WHERE space = ?1 AND user = ?2");
        defer finish(st);
        bind_blob(st, 1, space);
        bind_blob(st, 2, user);
        yes = row(st);
    }
    return yes;
}

// What a create or update carries. `html` holds the decoded file bytes.
struct Upload {
    id: u8[16], has_id: bool,
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

// --- storage --------------------------------------------------------------------
//
// A page is the file <pages-dir>/<id>.html, which nginx serves as it is. The
// space it belongs to, if any, is the one line of <pages-dir>/.spaces/<id>;
// the write rules need it, and nginx never serves that directory. A page
// unwritten for --pages-max-age days is deleted by the nightly prune, which
// keeps its .spaces line ("owner" for a page outside a space) so its old
// link can only be republished by whoever could write it before. Both are
// written atomically (a new file renamed over the old). Page operations run
// under the database write gate (begin_write), so a check and the write it
// allows can't interleave with another request's.

extern fn ib_file_mtime(path: const u8[:]) -> i64;

fn require_pages_dir() {
    if CFG.pages_dir.len == 0 { fail(404, "Page publishing isn't enabled on this server"); }
}

fn page_path(id: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    format(p, CFG.pages_dir, "/");
    format_uuid(p, id);
    p.append(".html");
    return p;
}

fn space_path(id: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    format(p, CFG.pages_dir, "/.spaces/");
    format_uuid(p, id);
    return p;
}

// What the write rules need to know about a page id. `claimed`: someone owns
// the id (the page exists, or it expired and left its .spaces line).
struct PageRow { exists: bool, claimed: bool, space: u8[16], has_space: bool }

let OWNER_MARK = "owner";

fn load_page(id: const u8[:]) -> PageRow {
    var r = PageRow { .. };
    r.exists = file_exists(page_path(id));
    r.claimed = r.exists;
    var line: u8[>..] = [];
    if read_file(space_path(id), line) {
        r.claimed = true;
        let s, ok = parse_uuid(trim(line));
        if ok { r.space = s; r.has_space = true; }
    }
    return r;
}

fn write_space(id: const u8[:], has_space: bool, space: const u8[:]) {
    if !has_space { delete_file(space_path(id)); return; }
    var line: u8[>..] = [];
    format_uuid(line, space);
    line.push('\n');
    if !write_file_atomic(space_path(id), line) { fail(500, "could not save the page"); }
}

fn write_html(id: const u8[:], html: const u8[:]) {
    if !write_file_atomic(page_path(id), html) { fail(500, "could not save the page"); }
}

// Writes a page (and its space) to the pages dir. The migration that moved
// pages out of the database uses this too.
fn store_page(id: const u8[:], html: const u8[:], has_space: bool, space: const u8[:]) {
    // The space first, so a page is never readable before its owner is known.
    write_space(id, has_space, space);
    write_html(id, html);
}

// POST /api/records/v1/pages. Re-posting an existing id overwrites it.
fn create_page(c: Ctx&) {
    require_pages_dir();
    let user = writer(c);
    var html: u8[>..] = [];
    let u = read_upload(c, html);
    if !u.has_id { fail(400, "id is required"); }
    if !u.has_html { fail(400, "html is required"); }
    if html.len > MAX_PAGE { fail(413, "page too large"); }
    let space: const u8[:] = if u.has_space { u.space[..] } else { "" };

    begin_write();
    let r = load_page(u.id);
    // A member may claim a new id for their space, or write their space's
    // page; never one that belongs to another space or to none.
    let as_owner = is_owner(user);
    let as_member = u.has_space && is_space_member(space, user)
                    && (!r.claimed || (r.has_space && r.space == u.space));
    if !as_owner && !as_member { fail(403, "Forbidden"); }
    store_page(u.id, html, u.has_space, space);
    commit();
    write_ids(c, u.id);
}

fn may_modify(r: PageRow&, user: const u8[:]) -> bool {
    is_owner(user) || (r.has_space && is_space_member(r.space, user))
}

// PATCH /api/records/v1/pages/{id}: replace the file and/or move it to a space.
fn update_page(c: Ctx&, id_s: const u8[:]) {
    require_pages_dir();
    let user = writer(c);
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "id must be a UUID"); }
    var html: u8[>..] = [];
    let u = read_upload(c, html);
    if u.has_id && u.id != id { fail(400, "id can't be changed"); }
    begin_write();
    let r = load_page(id);
    if !r.exists { fail(404, "no such page"); }
    // A member may update a page in their space but not move it to another one.
    let owner = is_owner(user);
    let member = r.has_space && is_space_member(r.space, user) && (!u.has_space || u.space == r.space);
    if !owner && !member { fail(403, "Forbidden"); }
    if u.has_space { write_space(id, true, u.space); }
    if u.has_html {
        if html.len > MAX_PAGE { fail(413, "page too large"); }
        write_html(id, html);
    }
    commit();
}

// DELETE /api/records/v1/pages/{id}
fn delete_page(c: Ctx&, id_s: const u8[:]) {
    require_pages_dir();
    let user = writer(c);
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "id must be a UUID"); }
    begin_write();
    let r = load_page(id);
    if !r.exists { fail(404, "no such page"); }
    if !may_modify(r, user) { fail(403, "Forbidden"); }
    delete_file(page_path(id));
    delete_file(space_path(id));
    commit();
    text(c, "deleted");
}

// Deletes pages whose file is older than --pages-max-age days (0: never),
// keeping who may republish them. Runs under the write gate, like page
// writes. Returns how many were deleted.
fn prune_pages() -> i64 {
    if CFG.pages_dir.len == 0 || CFG.pages_max_age <= 0 { return 0; }
    var names: u8[>..] = [];
    if !list_dir(CFG.pages_dir, names) { return 0; }
    let cutoff = now() - CFG.pages_max_age * 86400;
    var n = 0;
    begin_write();
    for name in split(names, '\n') {
        // <uuid>.html only: skips .spaces/ and the temp files of an atomic write.
        guard name.len == 41 && name[36..] == ".html" else { continue; }
        let id, ok = parse_uuid(name[..36]);
        guard ok else { continue; }
        let t = ib_file_mtime(page_path(id));
        guard t >= 0 && t < cutoff else { continue; }
        if !file_exists(space_path(id)) {
            var mark: u8[>..] = [];
            format(mark, OWNER_MARK, "\n");
            // Without its owner record, an expired id could be claimed by anyone.
            if !write_file_atomic(space_path(id), mark) { continue; }
        }
        if delete_file(page_path(id)) { n++; }
    }
    commit();
    return n;
}

// GET /api/pages/{id}: the file, inline. In production nginx serves the
// pages dir itself; this is for development and the tests.
fn serve_page(c: Ctx&, id_s: const u8[:]) {
    require_pages_dir();
    let id, ok = parse_uuid(id_s);
    if !ok { fail(400, "page id must be a UUID"); }
    if !read_file(page_path(id), c.out) { fail(404, "no such page"); }
    c.ctype = HTML;
}
