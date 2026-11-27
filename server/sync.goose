// POST /api/data/{app}: the last-write-wins sync protocol.
//
// `user_data` is append-only. Each upload inserts rows; "latest value per key"
// is derived at read time with ROW_NUMBER() over (scope, app, key) by id
// descending. A scope is the caller's personal rows (space IS NULL) or one
// shared space. Keys and values are stored as the compact JSON text of what
// the client sent, written byte-for-byte as serde_json would, and echoed back
// as strings, so existing clients keep their wire format.
import std;
import json;
import dictionary;
import exception;
import .util;
import .db;
import .http;
import .auth;

let MAX_DEPTH = 128;

// One uploaded item: its key and value text live in a shared builder.
struct Item { key_at: i64, key_len: i64, val_at: i64, val_len: i64, scope: i64 }   // val_len -1: null; scope -1: personal

struct Cursor { id: u8[16], cursor: i64 }

// Writes `n` as compact JSON, exactly as serde_json::to_string would.
recursive fn canon(n: json::Node&, out: u8[>..]&, depth: i64) {
    if depth > MAX_DEPTH { fail(400, "JSON nested too deeply"); }
    match n.val {
        Null => out.append("null"),
        Bool b => json::format_bool(out, b.v),
        Int i => json::format_int(out, i.v),
        Num x => json::format_number(out, x.v),
        Str s => json::format_string(out, s.s),
        Arr => {
            out.push('[');
            var ch: json::Node? = n.first;
            var first = true;
            while ch {
                if !first { out.push(','); }
                first = false;
                canon(ch, out, depth + 1);
                ch .= ch.next;
            }
            out.push(']');
        },
        Obj => {
            out.push('{');
            var ch: json::Node? = n.first;
            var first = true;
            while ch {
                if !first { out.push(','); }
                first = false;
                json::format_key(out, ch.key);
                canon(ch, out, depth + 1);
                ch .= ch.next;
            }
            out.push('}');
        },
    }
}

fn is_null_or_empty(n: json::Node&) -> bool {
    match n.val {
        Null => true,
        Str s => s.s.len == 0,
        _ => false,
    }
}

fn is_int(n: json::Node&) -> bool {
    match n.val { Int => true, _ => false }
}

fn sync_data(c: Ctx&, app: const u8[:]) {
    let user = caller_id(c);
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root = parse_json_body(c, doc, decoded);

    // --- validate the request ----------------------------------------------
    var last_synced: i64 = 0;
    var cur = json::member(root, "lastSyncedId");
    if !cur { cur .= json::member(root, "lastSyncId"); }
    if cur {
        let v, ok = json::as_i64(cur);
        if !ok { fail(400, "bad json: lastSyncedId must be an integer"); }
        last_synced = v;
    }
    if last_synced < 0 {
        exception::throw(Fail { status: 400, msg: str("Last Sync ID must be whole number but is \"", last_synced, "\".") });
    }

    let items_node = json::member(root, "data");
    if items_node {
        match items_node.val { Arr => {}, Null => {}, _ => fail(400, "bad json: data must be an array") }
    }

    // Spaces the caller belongs to for this app, in a stable order.
    var members: u8[16][>..] = [];
    {
        let st = query("""
            SELECT m.space FROM space_members m JOIN spaces s ON s.id = m.space
              WHERE m.user = ?1 AND s.app = ?2 ORDER BY s.created, m.space
            """);
        defer finish(st);
        bind_blob(st, 1, user);
        bind_text(st, 2, app);
        while row(st) { members.push(col_id(st, 0)); }
    }

    // Canonical key/value text for every item, plus its scope.
    var text: u8[>..] = [];
    var items: Item[>..] = [];
    if items_node {
        var i = 0;
        var it: json::Node? = items_node.first;
        while it {
            let key = json::member(it, "key");
            guard key && !is_null_or_empty(key) else {
                exception::throw(Fail { status: 400, msg: str("Key [", i, "] is required.") });
            }
            var scope = -1;
            let sp = json::member(it, "space");
            if sp {
                let s, is_str = json::as_string(sp);
                match sp.val {
                    Null => {},
                    _ => {
                        let id, ok = parse_uuid(s);
                        if !is_str || !ok {
                            exception::throw(Fail { status: 400, msg: str("Key [", i, "] has an invalid space id \"", s, "\".") });
                        }
                        for m, mi in members { if m == id { scope = mi; } }
                        if scope < 0 {
                            exception::throw(Fail { status: 403, msg: str("Not a member of space \"", s, "\".") });
                        }
                    },
                }
            }
            let key_at = text.len;
            canon(key, text, 0);
            let key_len = text.len - key_at;
            let val_at = text.len;
            var val_len = -1;
            let val = json::member(it, "data");
            if val && !(match val.val { Null => true, _ => false }) {
                canon(val, text, 0);
                val_len = text.len - val_at;
            }
            items.push(Item { key_at: key_at, key_len: key_len, val_at: val_at, val_len: val_len, scope: scope });
            i++;
            it .= it.next;
        }
    }

    // Cursors: personal first, then one per member space (default 0).
    var cursors: Cursor[>..] = [];
    for m in members { cursors.push(Cursor { id: m, cursor: 0 }); }
    let spaces_node = json::member(root, "spaces");
    if spaces_node {
        var e: json::Node? = spaces_node.first;
        while e {
            let id, ok = parse_uuid(e.key);
            if !ok { exception::throw(Fail { status: 400, msg: str("Invalid space id \"", e.key, "\".") }); }
            let v, is_i = json::as_i64(e);
            if !is_i { fail(400, "bad json: space cursors must be integers"); }
            if v < 0 {
                exception::throw(Fail { status: 400, msg: str("Cursor for space \"", e.key, "\" must be whole number but is \"", v, "\".") });
            }
            // Cursors for spaces the caller has left are ignored; the space's
            // absence from the response tells the client to drop it.
            for &cr in cursors { if cr.id == id { cr.cursor = v; } }
            e .= e.next;
        }
    }

    // (scope, key) of every uploaded item, to split pulled rows into data/conflicted.
    var ukeys: u8[>..] = [];
    var uploaded = dictionary<const u8[:], bool> {};
    {
        var spans: i64[>..] = [];
        for item in items {
            spans.push(ukeys.len);
            format(ukeys, item.scope, ":");
            ukeys.append(text[item.key_at..item.key_at + item.key_len]);
            spans.push(ukeys.len);
        }
        var k = 0;
        while k < spans.len {
            uploaded.insert(ukeys[spans[k]..spans[k + 1]], true);
            k += 2;
        }
    }

    // --- pull, then write ------------------------------------------------------
    if items.len > 0 { begin_write(); } else { begin(); }

    c.out.append("{\"data\":[");
    var conflicted: u8[>..] = [];
    var nd = 0;
    var nc = 0;
    var probe: u8[>..] = [];
    var kbuf: u8[>..] = [];
    var vbuf: u8[>..] = [];
    var tbuf: u8[>..] = [];
    for s in -1..cursors.len {
        let cursor = if s < 0 { last_synced } else { cursors[s].cursor };
        let st = if s < 0 {
            query("""
                WITH duplicates AS (
                  SELECT id, key, value, timestamp,
                  ROW_NUMBER() OVER (PARTITION BY user, app, key ORDER BY id DESC) AS dup
                  FROM user_data
                  WHERE id > ?1 AND user = ?2 AND app = ?3 AND space IS NULL)
                  SELECT key, value, id, timestamp FROM duplicates WHERE dup = 1 ORDER BY id
                """)
        } else {
            query("""
                WITH duplicates AS (
                  SELECT id, key, value, timestamp,
                  ROW_NUMBER() OVER (PARTITION BY space, app, key ORDER BY id DESC) AS dup
                  FROM user_data
                  WHERE id > ?1 AND space = ?2 AND app = ?3)
                  SELECT key, value, id, timestamp FROM duplicates WHERE dup = 1 ORDER BY id
                """)
        };
        defer finish(st);
        bind_int(st, 1, cursor);
        if s < 0 { bind_blob(st, 2, user); } else { bind_blob(st, 2, cursors[s].id); }
        bind_text(st, 3, app);
        var max_latest: i64 = 0;
        while row(st) {
            kbuf.clear();
            vbuf.clear();
            col_append(st, 0, kbuf);
            let has_val = !col_is_null(st, 1);
            col_append(st, 1, vbuf);
            let id = col_int(st, 2);
            if id > max_latest { max_latest = id; }
            probe.clear();
            format(probe, s, ":");
            probe.append(kbuf);
            if uploaded.contains(probe) {
                if nc > 0 { conflicted.push(','); }
                nc++;
                tbuf.clear();
                col_append(st, 3, tbuf);
                write_row(conflicted, kbuf, has_val, vbuf, id, tbuf, true, s, cursors);
            } else {
                if nd > 0 { c.out.push(','); }
                nd++;
                write_row(c.out, kbuf, has_val, vbuf, id, "", false, s, cursors);
            }
        }
        if s < 0 {
            if max_latest > last_synced { last_synced = max_latest; }
        } else if max_latest > cursors[s].cursor {
            cursors[s].cursor = max_latest;
        }
    }

    c.out.append("],\"saved\":[");
    for item, n in items {
        let st = query("INSERT INTO user_data (user, space, app, key, value) VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id");
        defer finish(st);
        bind_blob(st, 1, user);
        if item.scope < 0 { bind_null(st, 2); } else { bind_blob(st, 2, cursors[item.scope].id); }
        bind_text(st, 3, app);
        let key = text[item.key_at..item.key_at + item.key_len];
        bind_text(st, 4, key);
        if item.val_len < 0 { bind_null(st, 5); } else { bind_text(st, 5, text[item.val_at..item.val_at + item.val_len]); }
        var id: i64 = 0;
        if row(st) { id = col_int(st, 0); }
        if item.scope < 0 {
            if id > last_synced { last_synced = id; }
        } else if id > cursors[item.scope].cursor {
            cursors[item.scope].cursor = id;
        }
        if n > 0 { c.out.push(','); }
        c.out.append("{\"key\":");
        json::format_string(c.out, key);
        format(c.out, ",\"id\":", id);
        if item.scope >= 0 {
            c.out.append(",\"space\":\"");
            format_uuid(c.out, cursors[item.scope].id);
            c.out.push('"');
        }
        c.out.push('}');
    }

    commit();

    c.out.append("],\"conflicted\":[");
    c.out.append(conflicted);
    format(c.out, "],\"lastSyncedId\":", last_synced, ",\"spaces\":{");
    for cr, n in cursors {
        if n > 0 { c.out.push(','); }
        c.out.push('"');
        format_uuid(c.out, cr.id);
        format(c.out, "\":", cr.cursor);
    }
    c.out.append("}}");
    c.ctype = JSON;
}

// {"key":…,"data":…,"id":…[,"timestamp":…][,"space":…]}, the field order serde_json used.
fn write_row(out: u8[>..]&, key: const u8[:], has_val: bool, val: const u8[:], id: i64,
             ts: const u8[:], with_ts: bool, scope: i64, cursors: Cursor[:]) {
    out.append("{\"key\":");
    json::format_string(out, key);
    out.append(",\"data\":");
    if has_val { json::format_string(out, val); } else { out.append("null"); }
    format(out, ",\"id\":", id);
    if with_ts {
        out.append(",\"timestamp\":");
        json::format_string(out, ts);
    }
    if scope >= 0 {
        out.append(",\"space\":\"");
        format_uuid(out, cursors[scope].id);
        out.push('"');
    }
    out.push('}');
}
