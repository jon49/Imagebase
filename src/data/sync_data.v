module data

import db.sqlite

pub struct UploadedData {
    key string
    value string
    id int
}

pub struct SyncData {
    user_id int
    last_id int
    uploaded_data []UploadedData
}

pub struct SyncDataReturn {
    new_user_data []NewUserData
    conflicted_data []string
    last_synced_id i64
}

pub struct NewUserData {
    id int
    key string
    value string
}

pub fn sync_data(db &sqlite.DB, d SyncData) SyncDataReturn {
    latest_data := get_latest_data(db, d.user_id, d.last_id)
    mut last_synced_id := i64(0)

    mut new_user_data := []NewUserData{}
    /* mut conflicted_data := []string{} */
    if d.uploaded_data.len > 0 {
         data_to_save := d.uploaded_data.map(Data{
            id: it.id
            key: it.key
            user_id: d.user_id
            value: it.value
         })
        last_synced_id = save_data(db, data_to_save)
        /* for latest in latest_data { */
        /*     // if ids match from recently retrieved data from the database then */
        /*     // put in conflicted data. Otherwise put in `new_user_data` array. */
        /*     // I should probably return the data in the conflicted data so the */
        /*     // user can compare the two — if desired. */
        /*     if !latest.uploaded_data { */
        /*     } */
        /*     latest_data */
        /*     .filter(fn [d](x NewUserData) bool { */
        /*         return !d.uploaded_data */
        /*             .any(fn [x](y UploadedData) bool { return y.key == x.key && y.id > x.id }) */
        /*     }) */
        /* } */
        /* new_user_data = */
    }

    last_synced_id =
        if last_synced_id > 0 {
            last_synced_id
        } else {
            max(latest_data.map(it.id))
        }

    return SyncDataReturn{
        new_user_data: new_user_data
        last_synced_id: last_synced_id
    }
}

fn max(xs []int) int {
    mut max_value := 0
    for x in xs {
        max_value = if x > max_value { x } else { max_value }
    }
    return max_value
}


