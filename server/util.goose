// Small shared helpers: errors, UUIDs, base64url, hex, randomness, hashing.
import std;
import os;
import base64;
import exception;

// Every expected failure in a request (bad input, auth, not found, a database
// error) is thrown as a Fail and turned into a plain-text response by the
// dispatcher. Long-distance returns keep the handlers free of error plumbing.
struct Fail { status: i64, msg: u8[] }

fn fail(status: i64, msg: const u8[:]) {
    exception::throw(Fail { status: status, msg: msg });
}

// --- native crypto (native/crypto.c) -----------------------------------------

extern fn ib_sha256(data: const u8[:], out: u8[32]&);
extern fn ib_hmac_sha256(key: const u8[:], data: const u8[:], out: u8[32]&);
extern fn ib_ct_equal(a: const u8[:], b: const u8[:]) -> bool;
extern fn ib_random(out: u8[:]);
extern fn ib_argon2_hash(pw: const u8[:], out: u8[>..]&) -> bool;
extern fn ib_argon2_verify(encoded: const u8[:], pw: const u8[:]) -> bool;
extern fn ib_sendmail(cmd: const u8[:], msg: const u8[:]) -> bool;

fn sha256(data: const u8[:]) -> u8[32] {
    var h: u8[32] = [0; 32];
    ib_sha256(data, h);
    return h;
}

fn random16() -> u8[16] {
    var b: u8[16] = [0; 16];
    ib_random(b);
    return b;
}

// A random v4 UUID.
fn new_uuid() -> u8[16] {
    var b = random16();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return b;
}

// A fresh opaque token: `n` random bytes as unpadded base64url.
fn format_token(out: u8[>..]&, n: i64) {
    var raw: u8[64] = [0; 64];
    assert(n <= 64);
    ib_random(raw[..n]);
    b64url(out, raw[..n], false);
}

// --- hex and UUIDs ------------------------------------------------------------

let HEX = "0123456789abcdef";

fn format_hex(out: u8[>..]&, b: const u8[:]) {
    for c in b {
        out.push(HEX[c >> 4]);
        out.push(HEX[c & 15]);
    }
}

// The canonical hyphenated lowercase form.
fn format_uuid(out: u8[>..]&, id: const u8[:]) {
    for c, i in id {
        if i == 4 || i == 6 || i == 8 || i == 10 { out.push('-'); }
        out.push(HEX[c >> 4]);
        out.push(HEX[c & 15]);
    }
}

// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (dashes optional) to its 16 bytes.
fn parse_uuid(s: const u8[:]) -> u8[16], bool {
    var out: u8[16] = [0; 16];
    var n = 0;
    var hi = -1;
    for c in s {
        if c == '-' { continue; }
        let v = ascii::hex_value(c);
        if v < 0 || n >= 16 { return out, false; }
        if hi < 0 { hi = v; } else { out[n] = (hi * 16 + v) as! u8; n++; hi = -1; }
    }
    return out, n == 16 && hi < 0;
}

// --- base64url ------------------------------------------------------------------

fn b64url(out: u8[>..]&, src: const u8[:], padded: bool) {
    // Encoded in scratch and copied, so `out` itself only ever grows.
    var tmp: u8[>..] = [];
    base64::encode(tmp, src);
    for ch in tmp {
        if ch == '+' { out.push('-'); }
        else if ch == '/' { out.push('_'); }
        else if ch != '=' || padded { out.push(ch); }
    }
}

// Accepts url-safe or standard base64, padded or not.
fn b64_decode_any(out: u8[>..]&, src: const u8[:]) -> bool {
    var tmp: u8[>..] = [];
    for c in src {
        if c == '-' { tmp.push('+'); } else if c == '_' { tmp.push('/'); } else if c != '=' { tmp.push(c); }
    }
    while tmp.len % 4 != 0 { tmp.push('='); }
    return base64::decode(out, tmp);
}

// A user id on the wire: the 16-byte blob as padded url-safe base64, which is
// what TrailBase put in a token's `sub` and what space member lists expose.
fn format_user_id(out: u8[>..]&, id: const u8[:]) { b64url(out, id, true); }

fn parse_user_id(s: const u8[:]) -> u8[16], bool {
    var out: u8[16] = [0; 16];
    var raw: u8[>..] = [];
    if !b64_decode_any(raw, s) || raw.len != 16 { return out, false; }
    for b, i in raw { out[i] = b; }
    return out, true;
}

// --- misc -----------------------------------------------------------------------

fn now() -> i64 { (time() as i64) }

// make_dir for a path and each missing parent, like `mkdir -p`.
fn make_dirs(path: const u8[:]) -> bool {
    for ch, i in path {
        if ch == '/' && i > 0 { make_dir(path[..i]); }
    }
    return make_dir(path);
}

fn ascii_eq_nocase(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for c, i in a {
        if to_lower_ascii(c) != to_lower_ascii(b[i]) { return false; }
    }
    return true;
}

fn to_lower_ascii(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { c + 32 } else { c } }

fn log(msg: const u8[:]) {
    var line: u8[>..] = [];
    line.append(msg);
    line.push('\n');
    write_stderr(line);
}
