module data

import db.sqlite

pub struct SimpleData {
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
    new_user_data []SimpleData
    conflicted_data []SimpleData
    last_synced_id i64
}

pub fn sync_data(db &sqlite.DB, d SyncData) SyncDataReturn {
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

    last_synced_id :=
        max([
            save_data(db, map_simple_data_to_data(d.uploaded_data, d.user_id)),
            max(latest_data.map(i64(it.id)))
        ])

    return SyncDataReturn{
        conflicted_data: conflicted
        last_synced_id: last_synced_id
        new_user_data: new_user_data
    }

    /* mut conflicted_data := []string{} */
    /* if d.uploaded_data.len > 0 { */
    /*      data_to_save := d.uploaded_data.map(Data{ */
    /*         id: it.id */
    /*         key: it.key */
    /*         user_id: d.user_id */
    /*         value: it.value */
    /*      }) */
    /*     last_synced_id = save_data(db, data_to_save) */
    /*     /* for latest in latest_data { */ */
    /*     /*     // if ids match from recently retrieved data from the database then */ */
    /*     /*     // put in conflicted data. Otherwise put in `new_user_data` array. */ */
    /*     /*     // I should probably return the data in the conflicted data so the */ */
    /*     /*     // user can compare the two — if desired. */ */
    /*     /*     if !latest.uploaded_data { */ */
    /*     /*     } */ */
    /*     /*     latest_data */ */
    /*     /*     .filter(fn [d](x NewUserData) bool { */ */
    /*     /*         return !d.uploaded_data */ */
    /*     /*             .any(fn [x](y UploadedData) bool { return y.key == x.key && y.id > x.id }) */ */
    /*     /*     }) */ */
    /*     /* } */ */
    /*     /* new_user_data = */ */
    /* } */
    /**/
    /* last_synced_id = */
    /*     if last_synced_id > 0 { */
    /*         last_synced_id */
    /*     } else { */
    /*         max(latest_data.map(it.id)) */
    /*     } */

}

fn map_simple_data_to_data(simple_data []SimpleData, user_id int) []Data {
    return simple_data.map(fn [user_id](x SimpleData) Data {
        return Data{
            user_id: user_id
            key: x.key
            value: x.value
        }
    })
}

fn max(xs []i64) i64 {
    mut max_value := i64(0)
    for x in xs {
        max_value = if x > max_value { x } else { max_value }
    }
    return max_value
}


