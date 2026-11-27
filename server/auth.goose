// Accounts and sessions: the /api/auth/v1/* endpoints, wire-compatible with
// the TrailBase routes the frontends already call.
//
// Auth tokens are HS256 JWTs with TrailBase's claim set (sub, iat, exp, type,
// provider, email, username, csrf_token), signed with a per-data-dir secret.
// Refresh tokens are opaque random strings; only their SHA-256 is stored, as
// are the codes mailed for email verification and password reset.
import std;
import json;
import exception;
import .util;
import .db;
import .http;
import .config;
import .mail;

let MIN_PASSWORD = 8;
let MAX_PASSWORD = 128;
let VERIFY_TTL = 24 * 60 * 60;
let RESET_TTL = 60 * 60;
let RESET_INTERVAL = 60 * 60;        // one reset mail per address per hour
let LOGIN_WINDOW = 15 * 60;
let LOGIN_MAX_FAILURES = 10;          // per address per window, then 429

// {"alg":"HS256","typ":"JWT"}, base64url. The only header we issue or accept.
let JWT_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

// Verifying against this when the email is unknown keeps a miss as slow as a
// wrong password, so login timing doesn't reveal which addresses exist.
let DUMMY_HASH = "$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHRzb21lc2FsdA$CTFhFdXPJO1aFaMaO6Mm5c8y7cJHAph8ArZWb2GRPPc";

// --- tokens -------------------------------------------------------------------

fn sign(out: u8[>..]&, signing_input: const u8[:]) {
    var mac: u8[32] = [0; 32];
    ib_hmac_sha256(JWT_KEY, signing_input, mac);
    b64url(out, mac, false);
}

fn format_auth_token(out: u8[>..]&, id: const u8[:], email: const u8[:], csrf: const u8[:]) {
    let start = out.len;
    let t = now();
    var claims: u8[>..] = [];
    claims.append("{\"sub\":\"");
    format_user_id(claims, id);
    format(claims, "\",\"iat\":", t, ",\"exp\":", t + CFG.auth_ttl, ",\"type\":1,\"provider\":0,\"email\":");
    json::format_string(claims, email);
    claims.append(",\"username\":null,\"csrf_token\":");
    json::format_string(claims, csrf);
    claims.push('}');
    out.append(JWT_HEADER);
    out.push('.');
    b64url(out, claims, false);
    var input: u8[>..] = [];
    input.append(out[start..]);
    out.push('.');
    sign(out, input);
}

// The user id a valid, unexpired token was issued for; its csrf_token is
// appended to `csrf`.
fn verify_token(tok: const u8[:], csrf: u8[>..]&) -> u8[16], bool {
    var none: u8[16] = [0; 16];
    let dot1 = find(tok, ".");
    guard dot1 > 0 else { return none, false; }
    guard tok[..dot1] == JWT_HEADER else { return none, false; }
    let rest = tok[dot1 + 1..];
    let dot2 = find(rest, ".");
    guard dot2 > 0 else { return none, false; }
    var expect: u8[>..] = [];
    sign(expect, tok[..dot1 + 1 + dot2]);
    guard ib_ct_equal(expect, rest[dot2 + 1..]) else { return none, false; }

    var payload: u8[>..] = [];
    guard b64_decode_any(payload, rest[..dot2]) else { return none, false; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, _err = json::parse(payload, doc, decoded);
    guard root else { return none, false; }
    let exp, has_exp = json::as_i64(json::member(root, "exp"));
    guard has_exp && exp > now() else { return none, false; }
    let id, ok = parse_user_id(json_str(root, "sub"));
    guard ok else { return none, false; }
    csrf.append(json_str(root, "csrf_token"));
    return id, true;
}

// The authenticated caller. Tokens outlive account deletion until they
// expire, so the user must still exist; otherwise 401.
fn caller_id(c: Ctx&) -> u8[16] {
    let id, ok = caller_or_none(c);
    if !ok { fail(401, "Unauthorized"); }
    return id;
}

fn caller_or_none(c: Ctx&) -> u8[16], bool {
    var csrf: u8[>..] = [];
    let id, ok = verify_token(bearer_token(c), csrf);
    guard ok else { return id, false; }
    var exists = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("SELECT 1 FROM _user WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        exists = row(st);
    }
    return id, exists;
}

// --- input ---------------------------------------------------------------------

// A request's fields come as JSON or as a urlencoded form (HTML pages post those).
struct Fields { email: u8[..320], password: u8[..256], password_repeat: u8[..256], code: u8[..256], refresh: u8[..256] }

fn read_fields(c: Ctx&) -> Fields {
    var f = Fields { .. };
    if is_form(c) {
        form_into(c.body, "email", f.email);
        form_into(c.body, "password", f.password);
        form_into(c.body, "password_repeat", f.password_repeat);
        form_into(c.body, "password_reset_code", f.code);
        form_into(c.body, "refresh_token", f.refresh);
        return f;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root = parse_json_body(c, doc, decoded);
    put(f.email, json_str(root, "email"));
    put(f.password, json_str(root, "password"));
    put(f.password_repeat, json_str(root, "password_repeat"));
    put(f.code, json_str(root, "password_reset_code"));
    if f.code.len == 0 { put(f.code, json_str(root, "password_reset_token")); }
    put(f.refresh, json_str(root, "refresh_token"));
    return f;
}

fn put<B>(dst: B&, v: const u8[:]) {
    dst.clear();
    if v.len > dst.cap { fail(400, "Field too long"); }
    dst.append(v);
}

fn form_into<B>(body: const u8[:], key: const u8[:], dst: B&) {
    var v: u8[>..] = [];
    if form_value(body, key, v) { put(dst, v); }
}

fn valid_email(e: const u8[:]) -> bool {
    let at = find(e, "@");
    guard at > 0 && at < e.len - 3 && e.len <= 254 else { return false; }
    let domain = e[at + 1..];
    guard find(domain, "@") < 0 && find(domain, ".") > 0 && domain[domain.len - 1] != '.' else { return false; }
    for ch in e {
        if ch <= ' ' || ch == 0x7f || ch == '<' || ch == '>' || ch == ',' || ch == '"' || ch == '\\' { return false; }
    }
    return true;
}

fn check_new_password(pw: const u8[:], repeat: const u8[:]) {
    if pw.len < MIN_PASSWORD { fail(400, "Password too short"); }
    if pw.len > MAX_PASSWORD { fail(400, "Password too long"); }
    if pw != repeat { fail(400, "Passwords don't match"); }
}

fn hash_password(out: u8[>..]&, pw: const u8[:]) {
    if !ib_argon2_hash(pw, out) { fail(500, "Internal server error"); }
}

// SHA-256 of an emailed code or refresh token, as stored.
fn code_hash(code: const u8[:]) -> u8[32] { sha256(code) }

// --- register / verify ------------------------------------------------------

fn register(c: Ctx&) {
    let f = read_fields(c);
    if f.email.len == 0 { fail(400, "Missing email"); }
    if !valid_email(f.email) { fail(400, "Invalid email"); }
    check_new_password(f.password, f.password_repeat);

    var hash: u8[>..] = [];
    hash_password(hash, f.password);
    var code: u8[>..] = [];
    format_token(code, 32);
    let digest = code_hash(code);

    begin_write();
    var exists = false;
    {
        let st = query("SELECT 1 FROM _user WHERE email = ?1 OR unverified_email = ?1");
        defer finish(st);
        bind_text(st, 1, f.email);
        exists = row(st);
    }
    // An address that is already registered answers the same as a new one, so
    // the endpoint can't be used to find out who has an account.
    if !exists {
        let st = query("""
            INSERT INTO _user (id, unverified_email, password_hash, email_verification_code, email_verification_sent)
              VALUES (?1, ?2, ?3, ?4, UNIXEPOCH())
            """);
        defer finish(st);
        bind_blob(st, 1, new_uuid());
        bind_text(st, 2, f.email);
        bind_text(st, 3, hash);
        bind_blob(st, 4, digest);
        run(st);
    }
    commit();

    if !exists {
        var body: u8[>..] = [];
        format(body, "Welcome to ", CFG.app_name, ".\n\nConfirm your email address by opening this link:\n\n",
               CFG.site_url, "/api/auth/v1/verify_email/confirm/", code, "\n\nThe link is valid for 24 hours.\n");
        send_mail(f.email, "Confirm your email address", body);
    }
    text(c, "registered");
}

fn verify_email(c: Ctx&, code: const u8[:]) {
    begin_write();
    let st = query("""
        UPDATE _user SET email = unverified_email, unverified_email = NULL,
          email_verification_code = NULL, email_verification_sent = NULL,
          updated = UNIXEPOCH()
          WHERE email_verification_code = ?1 AND email_verification_sent > UNIXEPOCH() - ?2
          AND unverified_email IS NOT NULL
        """);
    defer finish(st);
    bind_blob(st, 1, code_hash(code));
    bind_int(st, 2, VERIFY_TTL);
    run(st);
    let ok = changes() == 1;
    commit();
    if !ok { fail(400, "Invalid token"); }
    page(c, "Email verified", "<p>Your email address is confirmed. You can now log in.</p>");
}

// --- login / sessions -----------------------------------------------------------

fn throttled(key: const u8[:]) -> bool {
    var hit = false;
    {   // defer in an inner block: see the note in db.goose
        let st = query("SELECT count FROM _auth_throttle WHERE key = ?1 AND window_start > UNIXEPOCH() - ?2");
        defer finish(st);
        bind_text(st, 1, key);
        bind_int(st, 2, LOGIN_WINDOW);
        hit = row(st) && col_int(st, 0) >= LOGIN_MAX_FAILURES;
    }
    return hit;
}

fn record_failure(key: const u8[:]) {
    let st = query("""
        INSERT INTO _auth_throttle (key, window_start, count) VALUES (?1, UNIXEPOCH(), 1)
          ON CONFLICT (key) DO UPDATE SET
          count = iif(window_start > UNIXEPOCH() - ?2, count + 1, 1),
          window_start = iif(window_start > UNIXEPOCH() - ?2, window_start, UNIXEPOCH())
        """);
    defer finish(st);
    bind_text(st, 1, key);
    bind_int(st, 2, LOGIN_WINDOW);
    run(st);
}

fn clear_failures(key: const u8[:]) {
    let st = query("DELETE FROM _auth_throttle WHERE key = ?1");
    defer finish(st);
    bind_text(st, 1, key);
    run(st);
}

// Starts a session and writes {"auth_token","refresh_token","csrf_token"}.
fn issue_session(c: Ctx&, id: const u8[:], email: const u8[:]) {
    var refresh: u8[>..] = [];
    format_token(refresh, 64);
    var csrf: u8[>..] = [];
    format_token(csrf, 18);
    {
        let st = query("INSERT INTO _session (user, token_hash, expires) VALUES (?1, ?2, UNIXEPOCH() + ?3)");
        defer finish(st);
        bind_blob(st, 1, id);
        bind_blob(st, 2, code_hash(refresh));
        bind_int(st, 3, CFG.refresh_ttl);
        run(st);
    }
    c.out.append("{\"auth_token\":\"");
    format_auth_token(c.out, id, email, csrf);
    c.out.append("\",\"refresh_token\":\"");
    c.out.append(refresh);
    c.out.append("\",\"csrf_token\":\"");
    c.out.append(csrf);
    c.out.append("\"}");
    c.ctype = JSON;
}

fn login(c: Ctx&) {
    let f = read_fields(c);
    if f.email.len == 0 { fail(400, "Missing email"); }
    var key: u8[>..] = [];
    key.append("login:");
    for ch in f.email { key.push(to_lower_ascii(ch)); }
    if throttled(key) { fail(429, "Too many attempts"); }

    var id: u8[16] = [0; 16];
    var email: u8[>..] = [];
    var hash: u8[>..] = [];
    var found = false;
    {
        let st = query("SELECT id, email, password_hash FROM _user WHERE email = ?1");
        defer finish(st);
        bind_text(st, 1, f.email);
        if row(st) {
            found = true;
            id = col_id(st, 0);
            col_append(st, 1, email);
            col_append(st, 2, hash);
        }
    }
    let ok = if found && hash.len > 0 { ib_argon2_verify(hash, f.password) }
             else { ib_argon2_verify(DUMMY_HASH, f.password); false };
    begin_write();
    if !ok {
        record_failure(key);
        commit();
        fail(401, "");
    }
    clear_failures(key);
    issue_session(c, id, email);
    commit();
}

fn refresh(c: Ctx&) {
    let f = read_fields(c);
    let st = query("""
        SELECT s.user, u.email FROM _session s JOIN _user u ON u.id = s.user
          WHERE s.token_hash = ?1 AND s.expires > UNIXEPOCH()
        """);
    defer finish(st);
    bind_blob(st, 1, code_hash(f.refresh));
    if !row(st) { fail(401, "Unauthorized"); }
    let id = col_id(st, 0);
    var email: u8[>..] = [];
    col_append(st, 1, email);
    var csrf: u8[>..] = [];
    format_token(csrf, 18);
    c.out.append("{\"auth_token\":\"");
    format_auth_token(c.out, id, email, csrf);
    c.out.append("\",\"csrf_token\":\"");
    c.out.append(csrf);
    c.out.append("\"}");
    c.ctype = JSON;
}

// With a refresh token, ends that session; with only a bearer token, ends all
// of the caller's sessions.
fn logout(c: Ctx&) {
    var refresh_token: u8[..256] = [];
    if c.method == "POST" {
        let f = read_fields(c);
        put(refresh_token, f.refresh);
    }
    begin_write();
    if refresh_token.len > 0 {
        let st = query("DELETE FROM _session WHERE token_hash = ?1");
        defer finish(st);
        bind_blob(st, 1, code_hash(refresh_token));
        run(st);
    } else {
        let id, ok = caller_or_none(c);
        if ok {
            let st = query("DELETE FROM _session WHERE user = ?1");
            defer finish(st);
            bind_blob(st, 1, id);
            run(st);
        }
    }
    commit();
    text(c, "logged out");
}

fn status(c: Ctx&) {
    var csrf: u8[>..] = [];
    let tok = bearer_token(c);
    let _id, ok = verify_token(tok, csrf);
    c.ctype = JSON;
    if !ok {
        c.out.append("{\"auth_token\":null,\"refresh_token\":null,\"csrf_token\":null}");
        return;
    }
    c.out.append("{\"auth_token\":");
    json::format_string(c.out, tok);
    c.out.append(",\"refresh_token\":null,\"csrf_token\":");
    json::format_string(c.out, csrf);
    c.out.push('}');
}

fn delete_account(c: Ctx&) {
    let id = caller_id(c);
    begin_write();
    let st = query("DELETE FROM _user WHERE id = ?1");
    defer finish(st);
    bind_blob(st, 1, id);
    run(st);
    commit();
    text(c, "deleted");
}

fn change_password(c: Ctx&) {
    let id = caller_id(c);
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root = parse_json_body(c, doc, decoded);
    let old_pw = json_str(root, "old_password");
    check_new_password(json_str(root, "new_password"), json_str(root, "new_password_repeat"));
    var hash: u8[>..] = [];
    {
        let st = query("SELECT password_hash FROM _user WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        if row(st) { col_append(st, 0, hash); }
    }
    if !ib_argon2_verify(hash, old_pw) { fail(401, "Unauthorized"); }
    var fresh: u8[>..] = [];
    hash_password(fresh, json_str(root, "new_password"));
    begin_write();
    {
        let st = query("UPDATE _user SET password_hash = ?2, updated = UNIXEPOCH() WHERE id = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        bind_text(st, 2, fresh);
        run(st);
    }
    commit();
    text(c, "password updated");
}

// --- password reset -------------------------------------------------------------

fn reset_request(c: Ctx&) {
    let f = read_fields(c);
    if f.email.len == 0 { fail(400, "Missing email"); }
    var code: u8[>..] = [];
    format_token(code, 32);
    begin_write();
    var recipient: u8[>..] = [];
    var too_soon = false;
    {
        let st = query("SELECT email, password_reset_sent > UNIXEPOCH() - ?2 FROM _user WHERE email = ?1");
        defer finish(st);
        bind_text(st, 1, f.email);
        bind_int(st, 2, RESET_INTERVAL);
        if row(st) {
            col_append(st, 0, recipient);
            too_soon = col_int(st, 1) == 1;
        }
    }
    if recipient.len > 0 && !too_soon {
        let st = query("UPDATE _user SET password_reset_code = ?2, password_reset_sent = UNIXEPOCH() WHERE email = ?1");
        defer finish(st);
        bind_text(st, 1, f.email);
        bind_blob(st, 2, code_hash(code));
        run(st);
    }
    commit();
    if too_soon { fail(429, "Too many requests"); }
    if recipient.len > 0 {
        var body: u8[>..] = [];
        format(body, "Someone asked to reset the password of your ", CFG.app_name, " account.\n\n",
               "To choose a new password, open this link within the next hour:\n\n",
               CFG.site_url, "/_/auth/reset_password/update/", code,
               "\n\nIf it wasn't you, ignore this email; your password stays as it is.\n");
        send_mail(recipient, "Reset your password", body);
    }
    text(c, "Password reset email sent");
}

// Sets the password for the account a live reset code belongs to and ends
// all of its sessions. False if the code is unknown or expired.
fn apply_reset(code: const u8[:], pw: const u8[:], repeat: const u8[:]) -> bool {
    check_new_password(pw, repeat);
    var hash: u8[>..] = [];
    hash_password(hash, pw);
    begin_write();
    var id: u8[16] = [0; 16];
    var found = false;
    {
        let st = query("SELECT id FROM _user WHERE password_reset_code = ?1 AND password_reset_sent > UNIXEPOCH() - ?2");
        defer finish(st);
        bind_blob(st, 1, code_hash(code));
        bind_int(st, 2, RESET_TTL);
        if row(st) { found = true; id = col_id(st, 0); }
    }
    if found {
        {
            let st = query("UPDATE _user SET password_hash = ?2, password_reset_code = NULL, updated = UNIXEPOCH() WHERE id = ?1");
            defer finish(st);
            bind_blob(st, 1, id);
            bind_text(st, 2, hash);
            run(st);
        }
        let st = query("DELETE FROM _session WHERE user = ?1");
        defer finish(st);
        bind_blob(st, 1, id);
        run(st);
    }
    commit();
    return found;
}

fn reset_update(c: Ctx&) {
    let f = read_fields(c);
    if !apply_reset(f.code, f.password, f.password_repeat) { fail(400, "Invalid token"); }
    text(c, "Password updated");
}

// The page the reset mail links to: a form that posts back to itself.
fn reset_form(c: Ctx&, code: const u8[:]) {
    if c.method == "POST" {
        var pw: u8[>..] = [];
        var repeat: u8[>..] = [];
        form_value(c.body, "password", pw);
        form_value(c.body, "password_repeat", repeat);
        var ok = false;
        var problem: u8[>..] = [];
        fn attempt() { ok = apply_reset(code, pw, repeat); }
        exception::try<Fail>(attempt) { e => problem.append(e.msg); };
        if ok {
            page(c, "Password updated", "<p>Your password has been changed. You can now log in with it.</p>");
            return;
        }
        rollback_if_open();
        var msg: u8[>..] = [];
        msg.append("<p class=err>");
        html_escape(msg, if problem.len > 0 { problem[..] } else { "This link is invalid or has expired." });
        msg.append("</p>");
        reset_page(c, code, msg);
        return;
    }
    reset_page(c, code, "");
}

fn reset_page(c: Ctx&, code: const u8[:], notice: const u8[:]) {
    var b: u8[>..] = [];
    b.append(notice);
    b.append("<form method=post action=\"/_/auth/reset_password/update/");
    html_escape(b, code);
    b.append("\"><label>New password <input type=password name=password minlength=8 required autofocus></label>");
    b.append("<label>Repeat it <input type=password name=password_repeat minlength=8 required></label>");
    b.append("<button>Set password</button></form>");
    page(c, "Choose a new password", b);
}

// Handlers write their response once, into an empty `out`.
fn page(c: Ctx&, title: const u8[:], content: const u8[:]) {
    c.out.append("<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>");
    html_escape(c.out, title);
    c.out.append("</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:26rem;margin:4rem auto;padding:0 1rem}");
    c.out.append("label{display:block;margin:.8rem 0}input{display:block;width:100%;padding:.4rem;font:inherit}");
    c.out.append("button{padding:.5rem 1rem;font:inherit}.err{color:#b00020}</style><h1>");
    html_escape(c.out, title);
    c.out.append("</h1>");
    c.out.append(content);
    c.ctype = HTML;
}

fn html_escape(out: u8[>..]&, s: const u8[:]) {
    for ch in s {
        if ch == '<' { out.append("&lt;"); }
        else if ch == '>' { out.append("&gt;"); }
        else if ch == '&' { out.append("&amp;"); }
        else if ch == '"' { out.append("&quot;"); }
        else { out.push(ch); }
    }
}
