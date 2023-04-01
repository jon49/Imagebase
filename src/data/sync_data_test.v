module data

import db.sqlite

// example can be found here:
// https://github.com/vlang/v/blob/master/vlib/db/sqlite/sqlite_test.v

fn test_sync_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    assert db.is_open
    create_result := create_db(mut db)
    assert create_result == 101 // Successful

    add_data(&db)

    result := get_latest_data(db, 1, 0)
    assert result.len == 2

    db.close() or { panic(err) }
    assert !db.is_open
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

