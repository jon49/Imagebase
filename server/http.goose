// The request/response surface the handlers see, over native/http.c.
import std;
import json;
import exception;
import .util;

// Must match ib_req_meta in native/http.c. The request's bytes arrive
// back to back in one buffer: method, target, header lines, body.
struct ReqMeta { conn: i64, method_len: i64, target_len: i64, headers_len: i64, body_len: i64 }

extern fn ib_http_listen(addr: const u8[:]) -> i64;
extern fn ib_http_next(slot: i64, meta: ReqMeta&, out: u8[>..]&) -> bool;
extern fn ib_http_respond(slot: i64, conn: i64, status: i64, headers: const u8[:], body: const u8[:]);
extern fn ib_http_abandon(slot: i64);
extern fn ib_http_wait_stop(ms: i64) -> bool;
extern fn ib_http_join();

let TEXT = "text/plain; charset=utf-8";
let JSON = "application/json";
let HTML = "text/html; charset=utf-8";

// One request in flight. `out` is the response body and `hdrs` extra
// response header lines; both are builders owned by the worker loop.
struct Ctx {
    method: const u8[:],
    path: const u8[:],
    query: const u8[:],
    headers: const u8[:],
    body: const u8[:],
    out: u8[>..]&,
    hdrs: u8[>..]&,
    ctype: const u8[:],
}

// The value of the first header called `name` (case-insensitive), or "".
fn header(c: Ctx&, name: const u8[:]) -> const u8[:] {
    var rest = c.headers;
    while rest.len > 0 {
        let line, after, _found = split_once(rest, "\r\n");
        rest = after;
        let k, v, ok = split_once(line, ':');
        if ok && ascii_eq_nocase(trim(k), name) { return trim(v); }
    }
    return "";
}

fn bearer_token(c: Ctx&) -> const u8[:] {
    let h = header(c, "authorization");
    if h.len > 7 && ascii_eq_nocase(h[..7], "bearer ") { return trim(h[7..]); }
    return "";
}

fn is_form(c: Ctx&) -> bool {
    let ct = header(c, "content-type");
    ct.len >= 33 && ascii_eq_nocase(ct[..33], "application/x-www-form-urlencoded")
}

fn is_multipart(c: Ctx&) -> bool {
    let ct = header(c, "content-type");
    ct.len >= 19 && ascii_eq_nocase(ct[..19], "multipart/form-data")
}

// The body as a JSON object, or null for an empty body. Bad JSON is a 400.
fn parse_json_body(c: Ctx&, doc: json::Node[>..]&, decoded: u8[>..]&) -> json::Node? {
    if trim(c.body).len == 0 { return null; }
    let root, err = json::parse(c.body, doc, decoded);
    guard root else {
        exception::throw(Fail { status: 400, msg: str("Invalid JSON body: ", err) });
    }
    return root;
}

fn json_str(n: json::Node?, key: const u8[:]) -> const u8[:] {
    let s, ok = json::as_string(json::member(n, key));
    if ok { s } else { "" }
}

// A short text body (handlers write their response once, into an empty `out`).
fn text(c: Ctx&, msg: const u8[:]) {
    c.out.append(msg);
    c.ctype = TEXT;
}

// --- application/x-www-form-urlencoded --------------------------------------

// Appends the decoded value of `key` in a urlencoded body to `out`; false if absent.
fn form_value(body: const u8[:], key: const u8[:], out: u8[>..]&) -> bool {
    var found = false;
    each_split(body, '&') {
        if !found {
            let k, v, _has = split_once(it, '=');
            if k == key {
                url_decode(out, v);
                found = true;
            }
        }
    };
    return found;
}

fn url_decode(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let ch = s[i];
        if ch == '+' { out.push(' '); i++; }
        else if ch == '%' && i + 2 < s.len && ascii::hex_value(s[i + 1]) >= 0 && ascii::hex_value(s[i + 2]) >= 0 {
            out.push((ascii::hex_value(s[i + 1]) * 16 + ascii::hex_value(s[i + 2])) as! u8);
            i += 3;
        } else { out.push(ch); i++; }
    }
}

// --- path matching ------------------------------------------------------------

// Splits a path like "/api/data/app" into its segments (without the leading /).
fn segments(path: const u8[:]) -> const u8[:][>..] {
    let p = if path.len > 0 && path[0] == '/' { path[1..] } else { path };
    return split(p, '/');
}
