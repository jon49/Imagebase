module data

import db.sqlite

pub struct Saved {
pub:
    id i64
    key string
}

pub struct SimpleData {
pub:
    key string
    id int
    value string
    timestamp string
}

pub struct SyncData {
    user_id int
    last_id int
    uploaded_data []SimpleData
}

pub struct SyncDataReturn {
pub:
    new_user_data []SimpleData
    conflicted_data []SimpleData
    saved []Saved
    last_synced_id i64
}

pub fn sync_data(db &sqlite.DB, d &SyncData) SyncDataReturn {
    latest_data := get_latest_data(db, d.user_id, d.last_id)

    mut new_user_data := []SimpleData{ cap: latest_data.len }
    mut conflicted := []SimpleData{ cap: latest_data.len }

    // When get latest data returns the same key as data that is being uploaded
    // that data is conflicted. Last write wins so we will overwrite the
    // previous data and add the conflicted data to a different array and let
    // the user determine which data to keep.
    for latest in latest_data {
        mut is_conflicted := false
        for new in d.uploaded_data {
            if new.key == latest.key {
                is_conflicted = true
                conflicted << latest
                break
            }
        }
        if is_conflicted { continue }
        new_user_data << SimpleData{
            id: latest.id
            key: latest.key
            value: latest.value
        }
    }

    mut uploaded_data := []Data{ cap: d.uploaded_data.len }
    for uploaded in d.uploaded_data {
        uploaded_data << Data{
            user_id: d.user_id
            key: uploaded.key
            value: uploaded.value
        }
    }
    saved := save_data(db, uploaded_data)

    mut ids := saved.map(it.id)
    ids << max(latest_data.map(i64(it.id)))
    last_synced_id := max(ids)

    return SyncDataReturn{
        conflicted_data: conflicted
        last_synced_id: last_synced_id
        new_user_data: new_user_data
        saved: saved
    }
}

fn max(xs []i64) i64 {
    mut max_value := i64(0)
    for x in xs {
        max_value = if x > max_value { x } else { max_value }
    }
    return max_value
}


