module data

import db.sqlite

// example can be found here:
// https://github.com/vlang/v/blob/master/vlib/db/sqlite/sqlite_test.v

fn test_sync_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    assert db.is_open
    create_db(mut db)
    db.exec("insert into data (user_id, key, value)
    values (1, 'key1', 'value1'),
        (2, 'key1', 'valueA')
        (1, 'key2', 'value2'),
        (1, 'key1', 'value3')")

    /* result := get_latest_data(db, 1, 0) */
    /* println(result) */
    println('Goodbye!')
}

