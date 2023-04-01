module data

import db.sqlite

fn test_get_latest_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    create_result := create_db(mut db)
    assert create_result == 101 // Successful

    for record in [
          "1, 'key1', 'valueA'",    // Original data
          "2, 'key1', 'valueB'",    // Different user
          "1, 'key2', 'valueC'",    // New data
          "1, 'key1', 'valueD'" ] { // Overwrite previous data
        insert_result :=
            db.exec_none(
                "INSERT INTO data ('user_id', 'key', 'value') VALUES (${record});")
        assert insert_result == 101
    }

    result := get_latest_data(db, 1, 0)
    assert result.len == 2

    first := result.first()
    assert first == NewUserData{
        id: 4
        key: 'key1'
        value: 'valueD'
    }

    last := result.last()
    assert last == NewUserData{
        id: 3
        key: 'key2'
        value: 'valueC'
    }

    db.close() or { panic(err) }
}

