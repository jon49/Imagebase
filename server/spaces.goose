// Shared-space membership and invites.
//
// Every member of a space has equal rights: any member can invite, list and
// remove members (themselves included). Non-members get 404 rather than 403
// so space ids can't be probed. Member ids on the wire are the user's id as
// unpadded url-safe base64 (padding is tolerated on input).
import std;
import exception;
import .util;
import .db;
import .http;
import .auth;

let INVITE_TTL = 7 * 24 * 60 * 60;

fn uuid_param(s: const u8[:], name: const u8[:]) -> u8[16] {
    let id, ok = parse_uuid(s);
    if !ok { exception::throw(Fail { status: 400, msg: str(name, " must be a UUID") }); }
    return id;
}

fn require_member(space: const u8[:], user: const u8[:]) {
    if !is_member(space, user) { fail(404, "no such space"); }
}

fn is_member(space: const u8[:], user: const u8[:]) -> bool {
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

// POST /api/spaces -> {"space": "<uuid>"}. The caller is the first member.
fn create_space(c: Ctx&) {
    let user = caller_id(c);
    let space = new_uuid();
    begin_write();
    {
        let st = query("INSERT INTO spaces (id, created_by) VALUES (?1, ?2)");
        defer finish(st);
        bind_blob(st, 1, space);
        bind_blob(st, 2, user);
        run(st);
    }
    {
        let st = query("INSERT INTO space_members (space, user) VALUES (?1, ?2)");
        defer finish(st);
        bind_blob(st, 1, space);
        bind_blob(st, 2, user);
        run(st);
    }
    commit();
    c.out.append("{\"space\":\"");
    format_uuid(c.out, space);
    c.out.append("\"}");
    c.ctype = JSON;
}

// GET /api/spaces/{space}/members -> {"members": [{"user","email","joined","me"}]}
fn list_members(c: Ctx&, space_s: const u8[:]) {
    let user = caller_id(c);
    let space = uuid_param(space_s, "space");
    begin();
    require_member(space, user);
    let st = query("""
        SELECT m.user, u.email, m.joined FROM space_members m JOIN _user u ON u.id = m.user
          WHERE m.space = ?1 ORDER BY m.joined, u.email
        """);
    defer finish(st);
    bind_blob(st, 1, space);
    c.out.append("{\"members\":[");
    var n = 0;
    var email: u8[>..] = [];
    while row(st) {
        if col_is_null(st, 1) { continue; }
        let id = col_id(st, 0);
        email.clear();
        col_append(st, 1, email);
        if n > 0 { c.out.push(','); }
        n++;
        c.out.append("{\"user\":\"");
        b64url(c.out, id, false);
        c.out.append("\",\"email\":");
        json::format_string(c.out, email);
        format(c.out, ",\"joined\":", col_int(st, 2), ",\"me\":", id == user, "}");
    }
    c.out.append("]}");
    commit();
    c.ctype = JSON;
}

// DELETE /api/spaces/{space}/members/{user|me}. Removing the last member
// deletes the space and its data; a removed member's open invites are revoked
// (both via triggers in the schema).
fn remove_member(c: Ctx&, space_s: const u8[:], target_s: const u8[:]) {
    let user = caller_id(c);
    let space = uuid_param(space_s, "space");
    var target = user;
    if target_s != "me" {
        // Tolerate padding, raw or percent-encoded, in case a client adds it.
        var raw: u8[>..] = [];
        url_decode(raw, target_s);
        let id, ok = parse_user_id(raw);
        if !ok { fail(400, "user must be a member id or \"me\""); }
        target = id;
    }
    begin_write();
    require_member(space, user);
    let st = query("DELETE FROM space_members WHERE space = ?1 AND user = ?2");
    defer finish(st);
    bind_blob(st, 1, space);
    bind_blob(st, 2, target);
    run(st);
    if changes() == 0 { fail(404, "no such member"); }
    commit();
    c.out.append("{}");
    c.ctype = JSON;
}

// POST /api/spaces/{space}/invites -> {"code": "<uuid>", "expires": <unix secs>}.
fn create_invite(c: Ctx&, space_s: const u8[:]) {
    let user = caller_id(c);
    let space = uuid_param(space_s, "space");
    begin_write();
    require_member(space, user);
    // Invites are only created here, so this keeps dead codes from piling up.
    exec("DELETE FROM space_invites WHERE expires < UNIXEPOCH()");
    let code = new_uuid();
    let st = query("""
        INSERT INTO space_invites (code, space, created_by, expires)
          VALUES (?1, ?2, ?3, UNIXEPOCH() + ?4) RETURNING expires
        """);
    defer finish(st);
    bind_blob(st, 1, code);
    bind_blob(st, 2, space);
    bind_blob(st, 3, user);
    bind_int(st, 4, INVITE_TTL);
    var expires: i64 = 0;
    if row(st) { expires = col_int(st, 0); }
    run(st);
    commit();
    c.out.append("{\"code\":\"");
    format_uuid(c.out, code);
    format(c.out, "\",\"expires\":", expires, "}");
    c.ctype = JSON;
}

// The space a live invite code grants; 404 if none.
fn invite_space(code: const u8[:]) -> u8[16] {
    let st = query("""
        SELECT space FROM space_invites WHERE code = ?1 AND expires >= UNIXEPOCH()
        """);
    defer finish(st);
    bind_blob(st, 1, code);
    if !row(st) { fail(404, "no such invite"); }
    return col_id(st, 0);
}

// GET /api/invites/{code} -> {"space","invitedBy","expires","member"}. Doesn't consume.
fn get_invite(c: Ctx&, code_s: const u8[:]) {
    let user = caller_id(c);
    let code = uuid_param(code_s, "code");
    begin();
    let space = invite_space(code);
    var email: u8[>..] = [];
    var expires: i64 = 0;
    {
        let st = query("SELECT u.email, i.expires FROM space_invites i JOIN _user u ON u.id = i.created_by WHERE i.code = ?1");
        defer finish(st);
        bind_blob(st, 1, code);
        if !row(st) || col_is_null(st, 0) { fail(404, "no such invite"); }
        col_append(st, 0, email);
        expires = col_int(st, 1);
    }
    let member = is_member(space, user);
    commit();
    c.out.append("{\"space\":\"");
    format_uuid(c.out, space);
    c.out.append("\",\"invitedBy\":");
    json::format_string(c.out, email);
    format(c.out, ",\"expires\":", expires, ",\"member\":", member, "}");
    c.ctype = JSON;
}

// POST /api/invites/{code}/accept -> {"space": "<uuid>"}. An existing member
// accepting is a no-op that leaves the invite usable for whoever it was meant for.
fn accept_invite(c: Ctx&, code_s: const u8[:]) {
    let user = caller_id(c);
    let code = uuid_param(code_s, "code");
    begin_write();
    let space = invite_space(code);
    if !is_member(space, user) {
        {
            let st = query("DELETE FROM space_invites WHERE code = ?1");
            defer finish(st);
            bind_blob(st, 1, code);
            run(st);
        }
        let st = query("INSERT INTO space_members (space, user) VALUES (?1, ?2)");
        defer finish(st);
        bind_blob(st, 1, space);
        bind_blob(st, 2, user);
        run(st);
    }
    commit();
    c.out.append("{\"space\":\"");
    format_uuid(c.out, space);
    c.out.append("\"}");
    c.ctype = JSON;
}
