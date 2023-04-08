module data

import db.sqlite

fn test_save_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    create_db(db) or { panic(err) }

    data := [
        Data{
            user_id: 2
            key: 'key1'
            value: 'valueA'
        },
        Data{
            user_id: 2
            key: 'key2'
            value: 'valueB'
        }
    ]

    result := save_data(&db, data) or { panic(err) }

    assert result == [
        Saved{
            id: 1
            key: 'key1' },
        Saved{
            id: 2
            key: 'key2'
        }]

    saved_data := sql db {
        select from Data
    } or { panic(err) }

    assert saved_data.len == 2

    first := saved_data.first()
    assert first == Data{
        id: 1
        user_id: 2
        key: 'key1'
        value: 'valueA'
        timestamp: first.timestamp
    }

    last := saved_data.last()
    assert last == Data{
        id: 2
        user_id: 2
        key: 'key2'
        value: 'valueB'
        timestamp: last.timestamp
    }

    db.close() or { panic(err) }
}

