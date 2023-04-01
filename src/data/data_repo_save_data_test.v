module data

import db.sqlite

fn test_save_data() {
    mut db := sqlite.connect(":memory:") or { panic(err) }
    create_db(db)

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

    result := save_data(&db, data)

    assert result == 2

    saved_data := sql db {
        select from Data
    }

    assert saved_data.len == 2

    assert saved_data.first() == Data{
        id: 1
        user_id: 2
        key: 'key1'
        value: 'valueA'
    }

    assert saved_data.last() == Data{
        id: 2
        user_id: 2
        key: 'key2'
        value: 'valueB'
    }

    db.close() or { panic(err) }
}

