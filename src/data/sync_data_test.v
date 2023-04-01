module data

import db.sqlite

// example can be found here:
// https://github.com/vlang/v/blob/master/vlib/db/sqlite/sqlite_test.v

fn test_sync_data_no_new_data_returns_latest_data() {
    mut db := set_up()
    add_data(db)

    sync := SyncData{
        user_id: 1
        last_id: 0
        uploaded_data: []SimpleData{}
    }
    result := sync_data(db, sync)

    assert result.new_user_data.len == 2
    assert result.conflicted_data.len == 0
    assert result.new_user_data == [
        SimpleData{ id: 3, key: 'key2', value: 'valueC' },
        SimpleData{ id: 4, key: 'key1', value: 'valueD' }
    ]

    db.close() or { panic(err) }
}

fn test_sync_data_returns_last_synced_record_id() {
    mut db := set_up()
    add_data(db)

    sync := SyncData{
        user_id: 1
        last_id: 0
        uploaded_data: []SimpleData{}
    }
    result := sync_data(db, sync)

    assert result.last_synced_id == 4

    db.close() or { panic(err) }
}

fn test_sync_data_inserts_new_data() {
    mut db := set_up()
    add_data(db)

    sync := SyncData{
        user_id: 1
        last_id: 0
        uploaded_data: [ SimpleData{ key: 'keyNew' value: 'Value New' } ]
    }
    result := sync_data(db, sync)

    // Make that last synced id is also updated.
    assert result.last_synced_id == 5
    assert result.new_user_data.len == 2

    results := sql db {
        select from Data
    }

    assert results.len == 5
    assert results[4] == Data{
        id: 5
        key: 'keyNew'
        value: 'Value New'
        user_id: 1
    }

    db.close() or { panic(err) }
}

// When get latest data returns the same key as data that is being uploaded that
// data is conflicted. Last write wins so we will overwrite the previous data
// and add the conflicted data to a different array and let the user determine
// which data to keep.
fn test_sync_data_handles_conflicting_data() {
    mut db := set_up()
    add_data(db)

    sync := SyncData{
        user_id: 1
        last_id: 0
        uploaded_data: [ SimpleData{ key: 'key1' value: 'Value New' } ]
    }
    result := sync_data(db, sync)

    // Make that last synced id is also updated.
    assert result.last_synced_id == 5
    assert result.new_user_data.len == 1
    assert result.conflicted_data.len == 1
    assert result.conflicted_data.first() == SimpleData{ id: 4 key: 'key1' value: 'valueD' }

    results := sql db {
        select from Data
    }

    assert results.len == 5
    assert results[4] == Data{
        id: 5
        key: 'key1'
        value: 'Value New'
        user_id: 1
    }

    db.close() or { panic(err) }
}

fn set_up() &sqlite.DB {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    create_db(db)
    return &db
}

fn add_data(db &sqlite.DB) {
    data := [
        Data{ user_id: 1, key: 'key1', value: 'valueA' },
        Data{ user_id: 2, key: 'key1', value: 'valueB' },
        Data{ user_id: 1, key: 'key2', value: 'valueC' },
        Data{ user_id: 1, key: 'key1', value: 'valueD' }
    ]
    save_data(db, data)
}

