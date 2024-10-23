module data

import db.sqlite

@[table: 'data']
struct Data {
	id        int @[primary; sql: serial]
	user_id   int
	key       string
	value     string @[null]
	timestamp string @[default: 'CURRENT_TIMESTAMP'; sql_type: 'DATETIME']
}

pub fn create_db(db &sqlite.DB) !int {
	sql db {
		create table Data
	}!
	result := db.exec_none('
CREATE UNIQUE INDEX IF NOT EXISTS idx_fetch ON data (id, user_id, key);
')
	return result
}

// Change to this when v sqlite has exec option for params
// "INSERT INTO {D.Table}
// ({D.Key}, {D.Source}, {D.UserId}, {D.Value})
// VALUES ({D._Key}, {D._Source}, {D._UserId}, {D._Value})
// RETURNING {D.Id}, {D.Key};"

fn save_data(db &sqlite.DB, data []Data) ![]Saved {
	mut saved := []Saved{cap: data.len}
	for d in data {
		sql db {
			insert d into Data
		}!
		last_id := db.last_insert_rowid()
		saved << &Saved{
			key: d.key
			id:  last_id
		}
	}

	return saved
}

fn get_latest_data(db &sqlite.DB, user_id int, last_id int) ![]SimpleData {
	// Once exec_param_many is created I'll be able to use this as a static
	// string instead this dynamic string
	get_data_query := '
WITH Duplicates AS (
	SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id, key ORDER BY id DESC) DupNum
	FROM data
    WHERE id > ${last_id}
      AND user_id = ${user_id}
)
SELECT d.key, d.value, d.id, d.timestamp
FROM Duplicates d
WHERE DupNum = 1
ORDER BY d.id;'

	rows := db.exec(get_data_query)!

	mut data := []SimpleData{len: rows.len}

	for i, row in rows {
		data[i] = SimpleData{
			key:       row.vals[0]
			value:     row.vals[1]
			id:        row.vals[2].int()
			timestamp: row.vals[3]
		}
	}

	return data
}
