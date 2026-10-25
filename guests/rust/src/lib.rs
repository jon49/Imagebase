use std::collections::{HashMap, HashSet};

use base64::{Engine as _, engine::general_purpose::URL_SAFE};
use serde::Deserialize;
use serde_json::{Value as JsonValue, json};
use trailbase_wasm::Guest;
use trailbase_wasm::db::{self, Transaction, Value};
use trailbase_wasm::fs;
use trailbase_wasm::http::{
    HeaderValue, HttpError, HttpRoute, IntoBody, Json, Request, Response, StatusCode, header, routing,
};
use trailbase_wasm::job::Job;

#[derive(Deserialize, Default)]
struct IncomingItem {
    key: JsonValue,
    #[serde(default)]
    data: Option<JsonValue>,
    // UUID of the shared space this row belongs to; absent = the caller's own data.
    #[serde(default)]
    space: Option<String>,
}

#[derive(Deserialize, Default)]
struct SyncRequest {
    // Cursor for the caller's personal rows only.
    #[serde(default, rename = "lastSyncedId", alias = "lastSyncId")]
    last_synced_id: i64,
    // Per-space cursors keyed by space UUID. A space the caller belongs to but
    // omits here starts at 0, so a newly joined space pulls its whole history.
    #[serde(default)]
    spaces: HashMap<String, i64>,
    #[serde(default)]
    data: Vec<IncomingItem>,
}

// Which slice of `user_data` a row lives in. Personal rows are scoped by user,
// shared rows by space; the two never mix in one "latest per key" window.
#[derive(Clone, PartialEq, Eq, Hash)]
enum Scope {
    Personal,
    Space(Vec<u8>),
}

async fn sync_data(mut req: Request) -> Result<Json<JsonValue>, HttpError> {
    let user_id_b64 = req
        .user()
        .ok_or_else(|| HttpError::message(StatusCode::UNAUTHORIZED, "Unauthorized"))?
        .id
        .clone();
    let user_id = URL_SAFE
        .decode(user_id_b64.as_bytes())
        .map_err(|_| HttpError::message(StatusCode::INTERNAL_SERVER_ERROR, "bad user id"))?;

    // Per-app scoping: the path segment carves out a namespace inside the
    // shared user_data table so multiple frontends can share one TrailBase.
    let app = req
        .path_param("app")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| HttpError::message(StatusCode::BAD_REQUEST, "app id is required"))?
        .to_owned();

    let body_bytes = req
        .body()
        .bytes()
        .await
        .map_err(|_| HttpError::message(StatusCode::BAD_REQUEST, "body read failed"))?;
    let body: SyncRequest = if body_bytes.is_empty() {
        SyncRequest::default()
    } else {
        serde_json::from_slice(&body_bytes).map_err(|e| {
            HttpError::message(StatusCode::BAD_REQUEST, format!("bad json: {e}"))
        })?
    };

    if body.last_synced_id < 0 {
        return Err(HttpError::message(
            StatusCode::BAD_REQUEST,
            format!(
                "Last Sync ID must be whole number but is \"{}\".",
                body.last_synced_id
            ),
        ));
    }
    for (i, item) in body.data.iter().enumerate() {
        let empty = matches!(&item.key, JsonValue::Null)
            || matches!(&item.key, JsonValue::String(s) if s.is_empty());
        if empty {
            return Err(HttpError::message(
                StatusCode::BAD_REQUEST,
                format!("Key [{i}] is required."),
            ));
        }
    }

    // Spaces the caller belongs to for this app, in a stable order for the
    // response. Membership is checked before the transaction so a rejected
    // batch never starts one.
    let member_rows = db::query(
        "SELECT m.space FROM space_members m JOIN spaces s ON s.id = m.space
         WHERE m.user = $1 AND s.app = $2
         ORDER BY s.created, m.space",
        &[Value::Blob(user_id.clone()), Value::Text(app.clone())],
    )
    .await
    .map_err(internal)?;
    let member_spaces: Vec<Vec<u8>> = member_rows
        .iter()
        .filter_map(|row| match row.first() {
            Some(Value::Blob(b)) => Some(b.clone()),
            _ => None,
        })
        .collect();

    let mut item_scopes = Vec::with_capacity(body.data.len());
    for (i, item) in body.data.iter().enumerate() {
        let scope = match &item.space {
            None => Scope::Personal,
            Some(s) => {
                let id = parse_uuid(s).ok_or_else(|| {
                    HttpError::message(
                        StatusCode::BAD_REQUEST,
                        format!("Key [{i}] has an invalid space id \"{s}\"."),
                    )
                })?;
                if !member_spaces.contains(&id) {
                    return Err(HttpError::message(
                        StatusCode::FORBIDDEN,
                        format!("Not a member of space \"{s}\"."),
                    ));
                }
                Scope::Space(id)
            }
        };
        item_scopes.push(scope);
    }

    let mut space_cursors: HashMap<Vec<u8>, i64> = HashMap::new();
    for (s, cursor) in &body.spaces {
        let id = parse_uuid(s).ok_or_else(|| {
            HttpError::message(StatusCode::BAD_REQUEST, format!("Invalid space id \"{s}\"."))
        })?;
        if *cursor < 0 {
            return Err(HttpError::message(
                StatusCode::BAD_REQUEST,
                format!("Cursor for space \"{s}\" must be whole number but is \"{cursor}\"."),
            ));
        }
        // Cursors for spaces the caller has left are ignored; the space's absence
        // from the response's `spaces` tells the client to drop it.
        space_cursors.insert(id, *cursor);
    }

    let uploaded_keys: HashSet<(Scope, String)> = body
        .data
        .iter()
        .zip(&item_scopes)
        .map(|(item, scope)| {
            (scope.clone(), serde_json::to_string(&item.key).unwrap_or_default())
        })
        .collect();

    let mut tx = Transaction::begin().map_err(internal)?;

    let mut data = Vec::new();
    let mut conflicted = Vec::new();
    let mut cursors: Vec<(Scope, i64)> = Vec::with_capacity(member_spaces.len() + 1);
    cursors.push((Scope::Personal, body.last_synced_id));
    for space in &member_spaces {
        let cursor = space_cursors.get(space).copied().unwrap_or(0);
        cursors.push((Scope::Space(space.clone()), cursor));
    }
    for (scope, cursor) in cursors.iter_mut() {
        let max_latest = pull(
            &mut tx,
            &user_id,
            &app,
            scope,
            *cursor,
            &uploaded_keys,
            &mut data,
            &mut conflicted,
        )?;
        *cursor = (*cursor).max(max_latest);
    }

    let mut saved = Vec::new();
    for (item, scope) in body.data.iter().zip(&item_scopes) {
        let key = serde_json::to_string(&item.key).unwrap_or_default();
        let value = match &item.data {
            None | Some(JsonValue::Null) => Value::Null,
            Some(v) => Value::Text(serde_json::to_string(v).unwrap_or_default()),
        };
        let space = match scope {
            Scope::Personal => Value::Null,
            Scope::Space(id) => Value::Blob(id.clone()),
        };
        let inserted = tx
            .query(
                "INSERT INTO user_data (user, space, app, key, value)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING id",
                &[
                    Value::Blob(user_id.clone()),
                    space,
                    Value::Text(app.clone()),
                    Value::Text(key.clone()),
                    value,
                ],
            )
            .map_err(internal)?;
        let id = match inserted.first().and_then(|r| r.first()) {
            Some(Value::Integer(i)) => *i,
            _ => 0,
        };
        if let Some((_, cursor)) = cursors.iter_mut().find(|(s, _)| s == scope) {
            *cursor = (*cursor).max(id);
        }
        saved.push(with_space(json!({ "key": key, "id": id }), scope));
    }

    tx.commit().map_err(internal)?;

    let mut last_synced_id = body.last_synced_id;
    let mut spaces = serde_json::Map::new();
    for (scope, cursor) in cursors {
        match scope {
            Scope::Personal => last_synced_id = cursor,
            Scope::Space(id) => {
                spaces.insert(format_uuid(&id), json!(cursor));
            }
        }
    }
    Ok(Json(json!({
        "data": data,
        "saved": saved,
        "conflicted": conflicted,
        "lastSyncedId": last_synced_id,
        "spaces": spaces,
    })))
}

// Rows written by any client since `cursor` within one scope, deduplicated by
// key keeping the most recent write (mirrors the original V/TS implementation).
// Keys in this batch go to `conflicted`, the rest to `data`. Returns the highest
// id seen.
#[allow(clippy::too_many_arguments)]
fn pull(
    tx: &mut Transaction,
    user_id: &[u8],
    app: &str,
    scope: &Scope,
    cursor: i64,
    uploaded_keys: &HashSet<(Scope, String)>,
    data: &mut Vec<JsonValue>,
    conflicted: &mut Vec<JsonValue>,
) -> Result<i64, HttpError> {
    let (column, owner, personal_only) = match scope {
        Scope::Personal => ("user", user_id.to_vec(), " AND space IS NULL"),
        Scope::Space(id) => ("space", id.clone(), ""),
    };
    let latest_rows = tx
        .query(
            &format!(
                "WITH duplicates AS (
                   SELECT id, key, value, timestamp,
                          ROW_NUMBER() OVER (PARTITION BY {column}, app, key ORDER BY id DESC) AS dup
                   FROM user_data
                   WHERE id > $1 AND {column} = $2 AND app = $3{personal_only}
                 )
                 SELECT key, value, id, timestamp
                 FROM duplicates
                 WHERE dup = 1
                 ORDER BY id"
            ),
            &[
                Value::Integer(cursor),
                Value::Blob(owner),
                Value::Text(app.to_owned()),
            ],
        )
        .map_err(internal)?;

    let mut max_latest: i64 = 0;
    for row in &latest_rows {
        let key = match row.first() {
            Some(Value::Text(s)) => s.clone(),
            _ => continue,
        };
        let value: Option<String> = match row.get(1) {
            Some(Value::Text(s)) => Some(s.clone()),
            _ => None,
        };
        let id = match row.get(2) {
            Some(Value::Integer(i)) => *i,
            _ => 0,
        };
        let timestamp = match row.get(3) {
            Some(Value::Text(s)) => s.clone(),
            _ => String::new(),
        };
        if id > max_latest {
            max_latest = id;
        }
        if uploaded_keys.contains(&(scope.clone(), key.clone())) {
            conflicted.push(with_space(
                json!({
                    "key": key,
                    "data": value,
                    "id": id,
                    "timestamp": timestamp,
                }),
                scope,
            ));
        } else {
            data.push(with_space(json!({ "key": key, "data": value, "id": id }), scope));
        }
    }
    Ok(max_latest)
}

// Tags a response row with its space. Personal rows stay untagged so clients
// that predate spaces see exactly the old wire format.
fn with_space(mut row: JsonValue, scope: &Scope) -> JsonValue {
    if let (Scope::Space(id), Some(obj)) = (scope, row.as_object_mut()) {
        obj.insert("space".to_owned(), json!(format_uuid(id)));
    }
    row
}

// Public, unauthenticated read of a page published via the `pages` Record API.
//
// The Record API stores only file metadata in `pages.html`; the bytes live in the
// object store. We can't use the Record API's own file endpoint because it forces
// `Content-Disposition: attachment` (browsers download instead of render), so we
// read the file straight off the object store — mounted read-only at the WASM FS
// root via `trail run --runtime-root-fs=<data-dir>/uploads` — and stream it back
// inline as `text/html`.
async fn serve_page(req: Request) -> Response {
    let app = match req.path_param("app").filter(|s| !s.is_empty()) {
        Some(a) => a.to_owned(),
        None => return text_response(StatusCode::BAD_REQUEST, "app id is required"),
    };
    let id = match req.path_param("id").filter(|s| !s.is_empty()) {
        Some(i) => i.to_owned(),
        None => return text_response(StatusCode::BAD_REQUEST, "page id is required"),
    };
    // `pages.id` is a 16-byte blob (see the migration); the client hands us the
    // canonical hyphenated form in the URL.
    let id_bytes = match parse_uuid(&id) {
        Some(bytes) => bytes,
        None => return text_response(StatusCode::BAD_REQUEST, "page id must be a UUID"),
    };

    let rows = match db::query(
        "SELECT html FROM pages WHERE app = $1 AND id = $2",
        &[Value::Text(app), Value::Blob(id_bytes)],
    )
    .await
    {
        Ok(rows) => rows,
        Err(e) => return text_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("{e}")),
    };

    let meta = match rows.first().and_then(|r| r.first()) {
        Some(Value::Text(s)) => s.as_str(),
        _ => return text_response(StatusCode::NOT_FOUND, "no such page"),
    };

    // `std.FileUpload` metadata: `{ "id": "<objectstore uuid>", ... }`. The object
    // store keys files by that uuid, flat under the uploads root.
    let object_id = serde_json::from_str::<JsonValue>(meta)
        .ok()
        .as_ref()
        .and_then(|v| v.get("id"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        .map(|s| s.to_owned());
    let object_id = match object_id {
        Some(s) => s,
        None => {
            return text_response(StatusCode::INTERNAL_SERVER_ERROR, "malformed page file metadata");
        }
    };

    let bytes = match fs::read_file(format!("/{object_id}")) {
        Ok(bytes) => bytes,
        Err(_) => return text_response(StatusCode::NOT_FOUND, "page file not found"),
    };

    let mut resp = Response::new(bytes.into_body());
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    resp
}

// Parse a canonical UUID string ("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", dashes
// optional) into its 16 raw bytes. No uuid crate — keeps the guest binary lean.
fn parse_uuid(s: &str) -> Option<Vec<u8>> {
    let hex: Vec<u8> = s.bytes().filter(|b| *b != b'-').collect();
    if hex.len() != 32 || !hex.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    let mut out = Vec::with_capacity(16);
    for pair in hex.chunks_exact(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

// Inverse of `parse_uuid`: 16 raw bytes to the canonical hyphenated lowercase form.
fn format_uuid(bytes: &[u8]) -> String {
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

fn text_response(status: StatusCode, body: &str) -> Response {
    let mut resp = Response::new(body.to_owned().into_body());
    *resp.status_mut() = status;
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    resp
}

// How long an overwritten row is kept before the nightly prune may delete it.
// SQLite modifier applied to `now`; rows whose timestamp is older than this are
// eligible. The latest write per (user, app, key) is never pruned.
const RETENTION_MODIFIER: &str = "-1 month";

// Nightly maintenance: drop rows that have been superseded by a newer write for
// the same key in the same scope AND are older than the retention window.
// user_data is append-only, so without this the table grows unbounded with stale
// history.
//
// The window mirrors the "latest value per key" derivation in `sync_data`: a
// personal row's scope is (user, app), a space row's is (space, app) regardless
// of which member wrote it. dup = 1 is the current value (always kept); dup > 1
// are overwrites. Recent overwrites stay reconcilable because only those older
// than RETENTION_MODIFIER are removed.
async fn prune_overwritten_data() -> Result<String, HttpError> {
    let cutoff = format!("strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '{RETENTION_MODIFIER}')");
    let deleted = db::execute(
        format!(
            "DELETE FROM user_data
             WHERE id IN (
               SELECT id FROM (
                 SELECT id, timestamp,
                        ROW_NUMBER() OVER (
                          PARTITION BY space, iif(space IS NULL, user, NULL), app, key
                          ORDER BY id DESC
                        ) AS dup
                 FROM user_data
               )
               WHERE dup > 1 AND timestamp < {cutoff}
             )"
        ),
        Vec::<Value>::new(),
    )
    .await
    .map_err(internal)?;

    Ok(format!("pruned {deleted} overwritten row(s)"))
}

fn internal<E: std::fmt::Display>(e: E) -> HttpError {
    HttpError::message(StatusCode::INTERNAL_SERVER_ERROR, format!("{e}"))
}

struct GuestImpl;

impl Guest for GuestImpl {
    fn http_handlers() -> Vec<HttpRoute> {
        vec![
            routing::post("/api/data/{app}", sync_data),
            routing::get("/api/pages/{app}/{id}", serve_page),
        ]
    }

    fn job_handlers() -> Vec<Job> {
        // Cron spec is "sec min hour day month weekday": 03:30 every night.
        vec![
            Job::new("prune_overwritten_data", "0 30 3 * * *", prune_overwritten_data)
                .expect("valid cron spec"),
        ]
    }
}

trailbase_wasm::export!(GuestImpl);
