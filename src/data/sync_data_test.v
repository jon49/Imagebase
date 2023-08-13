module data

import db.sqlite

// example can be found here:
// https://github.com/vlang/v/blob/master/vlib/db/sqlite/sqlite_test.v

fn test_sync_data_no_new_data_returns_latest_data() {
	mut db := set_up() or { panic(err) }
	add_data(db)

	sync := SyncData{
		user_id: 1
		last_id: 0
		uploaded_data: []SimpleData{}
	}
	result := sync_data(db, sync) or { panic(err) }

	assert result.new_user_data.len == 2
	assert result.conflicted_data.len == 0
	assert result.new_user_data == [
		SimpleData{
			id: 3
			key: 'key2'
			value: 'valueC'
		},
		SimpleData{
			id: 4
			key: 'key1'
			value: 'valueD'
		},
	]

	db.close() or { panic(err) }
}

fn test_sync_data_returns_last_synced_record_id() {
	mut db := set_up() or { panic(err) }
	add_data(db)

	sync := SyncData{
		user_id: 1
		last_id: 0
		uploaded_data: []SimpleData{}
	}
	result := sync_data(db, sync) or { panic(err) }

	assert result.last_synced_id == 4

	db.close() or { panic(err) }
}

fn test_sync_data_inserts_new_data() {
	mut db := set_up() or { panic(err) }
	add_data(db)

	sync := SyncData{
		user_id: 1
		last_id: 0
		uploaded_data: [SimpleData{
			key: 'keyNew'
			value: 'Value New'
		}]
	}
	result := sync_data(db, sync) or { panic(err) }

	// Make that last synced id is also updated.
	assert result.last_synced_id == 5
	assert result.new_user_data.len == 2
	assert result.saved.len == 1

	assert result.saved == [
		Saved{
			id: 5
			key: 'keyNew'
		},
	]

	results := sql db {
		select from Data
	} or { panic(err) }

	assert results.len == 5
	fifth := results[4]
	assert fifth == Data{
		id: 5
		key: 'keyNew'
		value: 'Value New'
		user_id: 1
		timestamp: fifth.timestamp
	}

	db.close() or { panic(err) }
}

fn test_sync_data_handles_conflicting_data() {
	mut db := set_up() or { panic(err) }
	add_data(db)

	sync := SyncData{
		user_id: 1
		last_id: 0
		uploaded_data: [SimpleData{
			key: 'key1'
			value: 'Value New'
		}]
	}
	result := sync_data(db, sync) or { panic(err) }

	// Make that last synced id is also updated.
	assert result.last_synced_id == 5
	assert result.new_user_data.len == 1
	assert result.conflicted_data.len == 1
	first := result.conflicted_data.first()
	assert first == SimpleData{
		id: 4
		key: 'key1'
		value: 'valueD'
		timestamp: first.timestamp
	}

	results := sql db {
		select from Data
	} or { panic(err) }

	assert results.len == 5
	fifth := results[4]
	assert fifth == Data{
		id: 5
		key: 'key1'
		value: 'Value New'
		user_id: 1
		timestamp: fifth.timestamp
	}

	db.close() or { panic(err) }
}

fn set_up() !&sqlite.DB {
	mut db := sqlite.connect(':memory:') or { panic(err) }
	create_db(db)!
	return &db
}

fn add_data(db &sqlite.DB) {
	data := [
		Data{
			user_id: 1
			key: 'key1'
			value: 'valueA'
		},
		Data{
			user_id: 2
			key: 'key1'
			value: 'valueB'
		},
		Data{
			user_id: 1
			key: 'key2'
			value: 'valueC'
		},
		Data{
			user_id: 1
			key: 'key1'
			value: 'valueD'
		},
	]
	save_data(db, data) or { panic(err) }
}
