use std::collections::HashSet;

use base64::{Engine as _, engine::general_purpose::URL_SAFE};
use serde::Deserialize;
use serde_json::{Value as JsonValue, json};
use trailbase_wasm::Guest;
use trailbase_wasm::db::{Transaction, Value};
use trailbase_wasm::http::{HttpError, HttpRoute, Json, Request, StatusCode, routing};

#[derive(Deserialize, Default)]
struct IncomingItem {
    key: JsonValue,
    #[serde(default)]
    data: Option<JsonValue>,
}

#[derive(Deserialize, Default)]
struct SyncRequest {
    #[serde(default, rename = "lastSyncedId", alias = "lastSyncId")]
    last_synced_id: i64,
    #[serde(default)]
    data: Vec<IncomingItem>,
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

    let mut tx = Transaction::begin().map_err(internal)?;

    // Rows written by any client since the cursor, deduplicated by key keeping
    // the most recent write. Mirrors the original V/TS implementation.
    let latest_rows = tx
        .query(
            "WITH duplicates AS (
               SELECT id, key, value, timestamp,
                      ROW_NUMBER() OVER (PARTITION BY user, key ORDER BY id DESC) AS dup
               FROM user_data
               WHERE id > $1 AND user = $2
             )
             SELECT key, value, id, timestamp
             FROM duplicates
             WHERE dup = 1
             ORDER BY id",
            &[
                Value::Integer(body.last_synced_id),
                Value::Blob(user_id.clone()),
            ],
        )
        .map_err(internal)?;

    let uploaded_keys: HashSet<String> = body
        .data
        .iter()
        .map(|item| serde_json::to_string(&item.key).unwrap_or_default())
        .collect();

    let mut data = Vec::new();
    let mut conflicted = Vec::new();
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
        if uploaded_keys.contains(&key) {
            conflicted.push(json!({
                "key": key,
                "data": value,
                "id": id,
                "timestamp": timestamp,
            }));
        } else {
            data.push(json!({ "key": key, "data": value, "id": id }));
        }
    }

    let mut saved = Vec::new();
    let mut max_saved: i64 = 0;
    for item in &body.data {
        let key = serde_json::to_string(&item.key).unwrap_or_default();
        let value = match &item.data {
            None | Some(JsonValue::Null) => Value::Null,
            Some(v) => Value::Text(serde_json::to_string(v).unwrap_or_default()),
        };
        let inserted = tx
            .query(
                "INSERT INTO user_data (user, key, value)
                 VALUES ($1, $2, $3)
                 RETURNING id",
                &[Value::Blob(user_id.clone()), Value::Text(key.clone()), value],
            )
            .map_err(internal)?;
        let id = match inserted.first().and_then(|r| r.first()) {
            Some(Value::Integer(i)) => *i,
            _ => 0,
        };
        if id > max_saved {
            max_saved = id;
        }
        saved.push(json!({ "key": key, "id": id }));
    }

    tx.commit().map_err(internal)?;

    let last_synced_id = body
        .last_synced_id
        .max(max_latest)
        .max(max_saved);
    Ok(Json(json!({
        "data": data,
        "saved": saved,
        "conflicted": conflicted,
        "lastSyncedId": last_synced_id,
    })))
}

fn internal<E: std::fmt::Display>(e: E) -> HttpError {
    HttpError::message(StatusCode::INTERNAL_SERVER_ERROR, format!("{e}"))
}

struct GuestImpl;

impl Guest for GuestImpl {
    fn http_handlers() -> Vec<HttpRoute> {
        vec![routing::post("/api/data", sync_data)]
    }
}

trailbase_wasm::export!(GuestImpl);
