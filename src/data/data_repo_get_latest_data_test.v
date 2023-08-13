module data

import db.sqlite

fn test_get_latest_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    create_result := create_db(&db) or { panic(err) }
    assert create_result == 101 // Successful

    data := [
        Data{ user_id: 1, key: 'key1', value: 'valueA' }, // Original data
        Data{ user_id: 2, key: 'key1', value: 'valueB' }, // Different user
        Data{ user_id: 1, key: 'key2', value: 'valueC' }, // New data
        Data{ user_id: 1, key: 'key1', value: 'valueD' }, // Overwritten Data
    ]
    save_data(db, data) or { panic(err) }

    result := get_latest_data(db, 1, 0)!
    assert result.len == 2

    first := result.first()
    assert first == SimpleData{
        id: 3
        key: 'key2'
        value: 'valueC'
        timestamp: first.timestamp
    }

    last := result.last()
    assert last == SimpleData{
        id: 4
        key: 'key1'
        value: 'valueD'
        timestamp: last.timestamp
    }

    db.close() or { panic(err) }
}

