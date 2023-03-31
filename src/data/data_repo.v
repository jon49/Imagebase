module data

import db.sqlite
// import msg { validate, assert_found, has_content }

struct Data {
    id int          [primary; sql: serial]
    user_id int     [nonull]
    key string      [nonull]
    value string
}

fn create_db(mut db &sqlite.DB) {
    sql db {
        create table Data
    }
    db.exec_none('CREATE UNIQUE INDEX IF NOT EXISTS idx_fetch ON data (id, user_id, key);')
}

fn save_data(db &sqlite.DB, data []Data) int {
    for d in data {
        sql db {
            insert d into Data
        }
    }
    max_id := 'SELECT MAX(id) FROM data;'
    return max_id.int()
}

fn get_latest_data(db &sqlite.DB, user_id int, last_id int) []NewUserData {
    // Once exec_param_many is created I'll be able to use this as a static
    // string instead this dynamic string
    get_data_query := '
WITH Duplicates AS (
	SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, key ORDER BY id DESC) DupNum
	FROM data
    WHERE id > ${last_id}
      AND user_id = ${user_id}
)
SELECT d.key, d.value, d.id
FROM Duplicates d
WHERE DupNum = 1;'
    
    rows, _ := db.exec(get_data_query)

    mut data := []NewUserData{ len: rows.len }

    for i, row in rows {
        data[i] = NewUserData{
            key: row.vals[0]
            value: row.vals[1]
            id: row.vals[2].int()
        }
    }

    return data
}

