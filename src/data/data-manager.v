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
    last_synced_id int
}

pub struct NewUserData {
    id int
    key string
    value string
}

pub sync_data(db &sqlite.DB, d SyncData) SyncDataReturn {
    latest_data = db.get_latest_data(db, d.user_id, d.last_id)
    mut last_synced_id := 0

    mut new_user_data := []NewUserData{}
    if d.uploaded_data.len > 0 {
         data_to_save := d.uploaded_data.map(Data{
            id: it.id
            key: it.key
            user_id: d.user_id
            value: it.value
         }
        last_synced_id = save_data(data_to_save);
        new_user_data =
            latest_data
            .filter(fn (x) bool {
                return !d.uploaded_data.any(it.key == x.key && it.id > x.id)
            })
    }

    last_synced_id =
        if last_synced_id > 0 {
            last_synced_id
        } else {
            max(latest_data.map(it.id));
        }

    return SyncDataReturn{
        new_user_data: latest_data
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

